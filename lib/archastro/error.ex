# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Error do
  @moduledoc "Typed REST API or transport error."
  defexception [:message, :status, :code, :details, :request_id, :reason]

  @type transport_reason :: Exception.t() | atom() | tuple()
  @type reason :: t() | transport_reason()

  @type t :: %__MODULE__{
          message: String.t(),
          status: integer() | nil,
          code: String.t() | nil,
          details: ArchAstro.SDK.JSON.t() | nil,
          request_id: String.t() | nil,
          reason: transport_reason() | nil
        }

  @spec from_response(Req.Response.t()) :: t()
  def from_response(response) do
    body = if is_map(response.body) and not is_struct(response.body), do: response.body, else: %{}
    error = body["error"]
    envelope = if is_map(error) and not is_struct(error), do: error, else: body

    message =
      envelope["message"] ||
        if(is_binary(error), do: error) ||
        "ArchAstro API returned HTTP #{response.status}"

    %__MODULE__{
      message: message,
      status: response.status,
      code: envelope["code"] || body["code"],
      details: envelope["details"] || body["details"] || body,
      request_id: Req.Response.get_header(response, "x-request-id") |> List.first()
    }
  end

  @spec transport(transport_reason()) :: t()
  def transport(reason),
    do: %__MODULE__{message: "ArchAstro transport error", reason: reason}

  @spec channel(ArchAstro.SDK.JSON.t() | transport_reason() | t()) :: t()
  def channel(%__MODULE__{} = error), do: error
  def channel({:error, payload}), do: channel(payload)

  def channel(reason) when is_map(reason) and not is_struct(reason) do
    nested = reason["error"]
    envelope = if is_map(nested) and not is_struct(nested), do: nested, else: reason

    %__MODULE__{
      message:
        envelope["message"] || envelope["reason"] ||
          if(is_binary(nested), do: nested) || "ArchAstro channel operation failed",
      code: envelope["code"] || reason["code"],
      details: envelope["details"] || reason
    }
  end

  def channel(reason) when is_binary(reason),
    do: %__MODULE__{message: reason, details: reason}

  def channel(reason), do: transport(reason)
end
