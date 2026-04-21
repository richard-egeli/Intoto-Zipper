defmodule SynologyZipper.State do
  @moduledoc """
  The persistence boundary for the application — all DB reads/writes
  go through here. Every mutation broadcasts a `Phoenix.PubSub` event
  so LiveViews refresh without polling.

  This is the Elixir port of `internal/state/store.go`; function
  names and semantics match the Go originals (one-to-one) but return
  shapes are idiomatic Elixir structs/tuples.

  PubSub topics:
    * `"sources"`              — `{:source_changed, name}` / `{:source_deleted, name}`
    * `"source:\#{name}"`       — `{:source_changed, name}`, `{:source_deleted, name}`,
                                  `{:month_changed, name, month}`,
                                  `{:month_deleted, name, month}`
    * `"runs"`                 — `{:run_changed, run_id}`
  """

  import Ecto.Query, warn: false

  alias SynologyZipper.Repo
  alias SynologyZipper.State.{Month, Run, Setting, Source}

  @drive_credentials_key "drive_credentials"

  @pubsub SynologyZipper.PubSub

  # ---------------------------------------------------------------------------
  # Source CRUD
  # ---------------------------------------------------------------------------

  @doc "Lists every source ordered by name."
  def list_sources do
    Repo.all(from s in Source, order_by: s.name)
  end

  @doc "Returns a single source or nil."
  def get_source(name), do: Repo.get(Source, name)

  @doc "Returns a single source or raises."
  def get_source!(name), do: Repo.get!(Source, name)

  @doc "Returns true if any configured source has auto_upload=true."
  def any_auto_upload? do
    Repo.exists?(from s in Source, where: s.auto_upload == true)
  end

  @doc """
  Upserts a source (matched by `:name`). Validates via the Source
  changeset. On success, broadcasts `{:source_changed, name}`.
  """
  def upsert_source(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name")

    existing =
      case name do
        nil -> nil
        n -> get_source(n)
      end

    changeset =
      case existing do
        nil -> Source.changeset(%Source{}, attrs)
        src -> Source.changeset(src, attrs)
      end

    case Repo.insert_or_update(changeset) do
      {:ok, source} ->
        broadcast_source_changed(source.name)
        {:ok, source}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Transactionally renames a source, migrating its `months` rows to the
  new name. No-op when `old_name == new_name`.
  """
  def rename_source(old_name, new_name) when old_name == new_name, do: {:ok, get_source(new_name)}

  def rename_source(_old_name, new_name) when new_name in [nil, ""] do
    {:error, :new_name_required}
  end

  def rename_source(old_name, new_name) do
    Repo.transaction(fn ->
      case Repo.get(Source, new_name) do
        nil -> :ok
        _ -> Repo.rollback({:conflict, new_name})
      end

      case Repo.get(Source, old_name) do
        nil ->
          Repo.rollback({:not_found, old_name})

        old ->
          # `:name` is the PK. To keep SQLite's FK happy without needing
          # deferred constraints, do: insert the new row first, re-point
          # the months, then drop the old row.
          new_row =
            Map.from_struct(old)
            |> Map.drop([:__meta__, :months])
            |> Map.put(:name, new_name)

          {:ok, renamed} =
            %Source{}
            |> Source.changeset(new_row)
            |> Repo.insert()

          from(m in Month, where: m.source_name == ^old_name)
          |> Repo.update_all(set: [source_name: new_name])

          {1, _} =
            from(s in Source, where: s.name == ^old_name)
            |> Repo.delete_all()

          renamed
      end
    end)
    |> case do
      {:ok, renamed} ->
        broadcast_source_changed(new_name)
        broadcast_source_deleted(old_name)
        {:ok, renamed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deletes a source and all its month rows. Broadcasts
  `{:source_deleted, name}`.
  """
  def delete_source(name) do
    Repo.transaction(fn ->
      from(m in Month, where: m.source_name == ^name) |> Repo.delete_all()
      from(s in Source, where: s.name == ^name) |> Repo.delete_all()
    end)
    |> case do
      {:ok, _} ->
        broadcast_source_deleted(name)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Month queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns a MapSet of months (`"YYYY-MM"`) where status='zipped' for
  the given source.
  """
  def zipped_months(source_name) do
    from(m in Month,
      where: m.source_name == ^source_name and m.status == "zipped",
      select: m.month
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Lists every month row for the given source, newest first."
  def list_months(source_name) do
    Repo.all(
      from m in Month,
        where: m.source_name == ^source_name,
        order_by: [desc: m.month]
    )
  end

  @doc "Returns one month row or nil."
  def get_month(source_name, month) do
    Repo.get_by(Month, source_name: source_name, month: month)
  end

  # ---------------------------------------------------------------------------
  # Month mutations (zip lifecycle)
  # ---------------------------------------------------------------------------

  @doc """
  Begins or retries a month attempt. Inserts a new row in status=failed
  (attempt_count=1) or updates an existing row, incrementing
  attempt_count and clearing the error. Matches the Go
  `StartMonthAttempt` upsert.
  """
  def start_month_attempt(source_name, month, at) do
    case get_month(source_name, month) do
      nil ->
        {:ok, m} =
          %Month{}
          |> Month.changeset(%{
            source_name: source_name,
            month: month,
            status: "failed",
            attempt_count: 1,
            last_attempt_at: at,
            started_at: at
          })
          |> Repo.insert()

        broadcast_month_changed(source_name, month)
        {:ok, m}

      existing ->
        {:ok, m} =
          existing
          |> Ecto.Changeset.change(%{
            status: "failed",
            attempt_count: existing.attempt_count + 1,
            last_attempt_at: at,
            started_at: at,
            error: nil
          })
          |> Repo.update()

        broadcast_month_changed(source_name, month)
        {:ok, m}
    end
  end

  @doc "Marks a month `zipped` with file metadata."
  def mark_zipped(source_name, month, at, zip_path, zip_bytes, file_count) do
    update_month(source_name, month, %{
      status: "zipped",
      finished_at: at,
      zip_path: zip_path,
      zip_bytes: zip_bytes,
      file_count: file_count,
      error: nil
    })
  end

  @doc """
  Marks a month `zipped` with no output (empty folder). Nil zip_path is
  how the planner / uploader recognise a no-op month.
  """
  def mark_zipped_empty(source_name, month, at) do
    update_month(source_name, month, %{
      status: "zipped",
      finished_at: at,
      zip_path: nil,
      zip_bytes: 0,
      file_count: 0,
      error: nil
    })
  end

  @doc "Marks a month `failed` with a human-readable error message."
  def mark_failed(source_name, month, at, err_msg) do
    update_month(source_name, month, %{
      status: "failed",
      finished_at: at,
      error: err_msg
    })
  end

  @doc """
  Deletes a month row so the planner re-considers it next tick.
  Returns `:ok` regardless of whether a row existed.
  """
  def reset_month(source_name, month) do
    {_, _} =
      from(m in Month, where: m.source_name == ^source_name and m.month == ^month)
      |> Repo.delete_all()

    broadcast_month_deleted(source_name, month)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Upload queries + mutations
  # ---------------------------------------------------------------------------

  @doc """
  Returns month rows eligible for Drive upload:

    * auto_upload=true on the source
    * status='zipped' on the month
    * drive_file_id='' (not yet uploaded)
    * zip_path not null/empty (there is a real file)

  Each row is `%{source_name, month, zip_path, drive_folder_id}`.
  """
  def months_pending_upload do
    from(m in Month,
      join: s in Source,
      on: s.name == m.source_name,
      where:
        s.auto_upload == true and
          m.status == "zipped" and
          m.drive_file_id == "" and
          not is_nil(m.zip_path) and
          m.zip_path != "",
      order_by: [asc: m.source_name, asc: m.month],
      select: %{
        source_name: m.source_name,
        month: m.month,
        zip_path: m.zip_path,
        drive_folder_id: s.drive_folder_id
      }
    )
    |> Repo.all()
  end

  @doc "Records a successful upload; increments `upload_attempts`, clears error."
  def mark_uploaded(source_name, month, file_id, at) do
    case get_month(source_name, month) do
      nil ->
        {:error, :not_found}

      row ->
        {:ok, _} =
          row
          |> Ecto.Changeset.change(%{
            drive_file_id: file_id,
            uploaded_at: at,
            upload_error: "",
            upload_attempts: row.upload_attempts + 1
          })
          |> Repo.update()

        broadcast_month_changed(source_name, month)
        :ok
    end
  end

  @doc """
  Records a failed upload. Leaves `drive_file_id=''` so the next tick
  retries the month.
  """
  def mark_upload_failed(source_name, month, err_msg) do
    case get_month(source_name, month) do
      nil ->
        {:error, :not_found}

      row ->
        {:ok, _} =
          row
          |> Ecto.Changeset.change(%{
            drive_file_id: "",
            upload_error: err_msg,
            upload_attempts: row.upload_attempts + 1
          })
          |> Repo.update()

        broadcast_month_changed(source_name, month)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Runs
  # ---------------------------------------------------------------------------

  @doc "Inserts a new run row with `started_at=at`. Returns the run."
  def start_run(at) do
    {:ok, run} =
      %Run{}
      |> Run.changeset(%{started_at: at})
      |> Repo.insert()

    broadcast_run_changed(run.id)
    run
  end

  @doc "Finalises a run row with counts, status, and optional notes."
  def finish_run(run_id, at, status, zipped, failed, notes) do
    run = Repo.get!(Run, run_id)

    {:ok, updated} =
      run
      |> Ecto.Changeset.change(%{
        finished_at: at,
        exit_status: status,
        months_zipped: zipped,
        months_failed: failed,
        notes: notes
      })
      |> Repo.update()

    broadcast_run_changed(run_id)
    updated
  end

  @doc "Returns the most recent `limit` runs, newest first."
  def list_runs(limit \\ 50) when is_integer(limit) do
    limit = if limit <= 0, do: 50, else: limit
    Repo.all(from r in Run, order_by: [desc: r.id], limit: ^limit)
  end

  # ---------------------------------------------------------------------------
  # Dashboard view
  # ---------------------------------------------------------------------------

  @doc """
  Source row with derived columns used by the dashboard:
    * `:last_zipped_month` — max month where status='zipped' or ""
    * `:last_run_status`   — latest month's status or ""
    * `:zipped_months`     — count of zipped months
    * `:uploaded_months`   — count with drive_file_id<>''
    * `:failed_uploads`    — count of zipped-but-errored uploads

  Returned as a plain map per row, not an Ecto struct.
  """
  def list_sources_with_stats do
    sources = list_sources()

    Enum.map(sources, fn s ->
      base = Map.from_struct(s) |> Map.drop([:__meta__, :months])

      Map.merge(base, %{
        last_zipped_month: last_zipped_month(s.name),
        last_run_status: last_run_status(s.name),
        zipped_months: count_months(s.name, status: "zipped"),
        uploaded_months: count_months(s.name, uploaded: true),
        failed_uploads: count_failed_uploads(s.name)
      })
    end)
  end

  defp last_zipped_month(source_name) do
    case Repo.one(
           from m in Month,
             where: m.source_name == ^source_name and m.status == "zipped",
             select: max(m.month)
         ) do
      nil -> ""
      v -> v
    end
  end

  defp last_run_status(source_name) do
    case Repo.one(
           from m in Month,
             where: m.source_name == ^source_name,
             order_by: [desc_nulls_last: m.last_attempt_at],
             limit: 1,
             select: m.status
         ) do
      nil -> ""
      v -> v
    end
  end

  defp count_months(source_name, status: status) do
    Repo.one(
      from m in Month,
        where: m.source_name == ^source_name and m.status == ^status,
        select: count(m.month)
    )
  end

  defp count_months(source_name, uploaded: true) do
    Repo.one(
      from m in Month,
        where: m.source_name == ^source_name and m.drive_file_id != "",
        select: count(m.month)
    )
  end

  defp count_failed_uploads(source_name) do
    Repo.one(
      from m in Month,
        where:
          m.source_name == ^source_name and m.status == "zipped" and
            m.drive_file_id == "" and m.upload_error != "",
        select: count(m.month)
    )
  end

  # ---------------------------------------------------------------------------
  # Drive credentials (uploaded JSON service-account key)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the parsed Google service-account credentials map, or `nil`
  when none have been uploaded. Failure to decode stored JSON is
  treated as "not configured" rather than an error so a corrupted row
  doesn't take the app down.
  """
  @spec get_drive_credentials() :: map() | nil
  def get_drive_credentials do
    with %Setting{value: json} <- Repo.get(Setting, @drive_credentials_key),
         {:ok, creds} <- Jason.decode(json) do
      creds
    else
      _ -> nil
    end
  end

  @doc """
  Returns just the service-account email for the uploaded
  credentials, or `nil` when none are configured. Used by the UI to
  show which account the app will upload as.
  """
  @spec get_drive_credentials_email() :: String.t() | nil
  def get_drive_credentials_email do
    case get_drive_credentials() do
      %{"client_email" => email} -> email
      _ -> nil
    end
  end

  @doc """
  Stores a Google service-account key (raw JSON string). Validates
  that the JSON parses and carries the two fields Goth needs
  (`client_email` + `private_key`). Broadcasts `:settings_changed` on
  success.
  """
  @spec put_drive_credentials(String.t()) ::
          {:ok, %Setting{}} | {:error, :invalid_json | :missing_required_fields | term()}
  def put_drive_credentials(json) when is_binary(json) do
    with {:ok, creds} <- Jason.decode(json),
         true <- has_required_fields?(creds) do
      result =
        %Setting{}
        |> Setting.changeset(%{key: @drive_credentials_key, value: json})
        |> Repo.insert(
          on_conflict: {:replace, [:value]},
          conflict_target: :key
        )

      case result do
        {:ok, _} = ok ->
          broadcast_settings_changed()
          ok

        {:error, _} = err ->
          err
      end
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      false -> {:error, :missing_required_fields}
    end
  end

  @doc "Removes any stored Drive credentials. Broadcasts `:settings_changed`. Idempotent."
  @spec delete_drive_credentials() :: :ok
  def delete_drive_credentials do
    from(s in Setting, where: s.key == ^@drive_credentials_key)
    |> Repo.delete_all()

    broadcast_settings_changed()
    :ok
  end

  defp has_required_fields?(%{"client_email" => e, "private_key" => k})
       when is_binary(e) and byte_size(e) > 0 and is_binary(k) and byte_size(k) > 0,
       do: true

  defp has_required_fields?(_), do: false

  # ---------------------------------------------------------------------------
  # PubSub topic helpers
  # ---------------------------------------------------------------------------

  @doc "Topic for sources-list events (`{:source_changed, name}`, `{:source_deleted, name}`)."
  def sources_topic, do: "sources"

  @doc "Per-source topic for month + source events."
  def source_topic(name), do: "source:#{name}"

  @doc "Topic for `{:run_changed, id}` events."
  def runs_topic, do: "runs"

  @doc "Topic for settings changes (`:settings_changed`). Currently just Drive credentials."
  def settings_topic, do: "settings"

  @doc "Subscribe the calling process to `sources_topic/0`."
  def subscribe_sources, do: Phoenix.PubSub.subscribe(@pubsub, sources_topic())

  @doc "Subscribe the calling process to `source_topic/1`."
  def subscribe_source(name), do: Phoenix.PubSub.subscribe(@pubsub, source_topic(name))

  @doc "Subscribe the calling process to `runs_topic/0`."
  def subscribe_runs, do: Phoenix.PubSub.subscribe(@pubsub, runs_topic())

  @doc "Subscribe the calling process to `settings_topic/0`."
  def subscribe_settings, do: Phoenix.PubSub.subscribe(@pubsub, settings_topic())

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp update_month(source_name, month, changes) do
    case get_month(source_name, month) do
      nil ->
        {:error, :not_found}

      row ->
        {:ok, m} =
          row
          |> Ecto.Changeset.change(changes)
          |> Repo.update()

        broadcast_month_changed(source_name, month)
        {:ok, m}
    end
  end

  defp broadcast_source_changed(name) do
    Phoenix.PubSub.broadcast(@pubsub, sources_topic(), {:source_changed, name})
    Phoenix.PubSub.broadcast(@pubsub, source_topic(name), {:source_changed, name})
  end

  defp broadcast_source_deleted(name) do
    Phoenix.PubSub.broadcast(@pubsub, sources_topic(), {:source_deleted, name})
    Phoenix.PubSub.broadcast(@pubsub, source_topic(name), {:source_deleted, name})
  end

  defp broadcast_month_changed(source_name, month) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      source_topic(source_name),
      {:month_changed, source_name, month}
    )
  end

  defp broadcast_month_deleted(source_name, month) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      source_topic(source_name),
      {:month_deleted, source_name, month}
    )
  end

  defp broadcast_run_changed(run_id) do
    Phoenix.PubSub.broadcast(@pubsub, runs_topic(), {:run_changed, run_id})
  end

  defp broadcast_settings_changed do
    Phoenix.PubSub.broadcast(@pubsub, settings_topic(), :settings_changed)
  end
end
