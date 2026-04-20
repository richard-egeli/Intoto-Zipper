defmodule SynologyZipper.Uploader.Job do
  @moduledoc "One upload request. Ports `UploadJob` from `internal/uploader`."

  @enforce_keys [:source_name, :month, :zip_path, :drive_folder_id]
  defstruct [:source_name, :month, :zip_path, :drive_folder_id]

  @type t :: %__MODULE__{
          source_name: String.t(),
          month: String.t(),
          zip_path: String.t(),
          drive_folder_id: String.t()
        }
end
