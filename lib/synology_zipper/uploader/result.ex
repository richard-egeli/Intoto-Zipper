defmodule SynologyZipper.Uploader.Result do
  @moduledoc "Successful upload outcome. Ports `UploadResult`."

  @enforce_keys [:drive_file_id]
  defstruct [:drive_file_id, bytes: 0, duration_ms: 0]

  @type t :: %__MODULE__{
          drive_file_id: String.t(),
          bytes: non_neg_integer(),
          duration_ms: non_neg_integer()
        }
end
