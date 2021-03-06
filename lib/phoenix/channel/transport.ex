defmodule Phoenix.Channel.Transport do
  @moduledoc """
  Handles dispatching incoming and outgoing Channel messages

  ## The Transport Adapter Contract

  The Transport layer dispatches `%Phoenix.Socket.Message{}`'s from remote clients,
  backed by different Channel transport implementations and serializations.

  ### Server

  To implement a Transport adapter, the Server must broker the following actions:

    * Handle receiving incoming, encoded `%Phoenix.Socket.Message{}`'s from
      remote clients, then deserialing and fowarding message through
      `Phoenix.Transport.dispatch/4`. Message keys must be deserialized as strings.
    * Handle receiving `{:ok, socket_pid}` results from Transport dispatch and storing a
      HashDict of a string topics to Pid matches, and Pid to String topic matches.
      The HashDict of topic => pids is dispatched through the transport layer's
      `Phoenix.Transport.dispatch/4`.
    * Handle receiving outgoing `%Phoenix.Socket.Message{}` and `%Phoenix.Socket.Reply{}` as
      Elixir process messages, then encoding and fowarding to remote client.
    * Trap exits and handle receiving `{:EXIT, socket_pid, reason}` messages
      and delete the entries from the kept HashDict of socket processes.
      When exits are received, the adapter transport must reply to their client
      with one of two messages:

        - for `:normal` exits and shutdowns, send a reply to the remote
          client of a message from `Transport.chan_close_message/1`
        - for abnormal exits, send a reply to the remote client of a message
          from `Transport.chan_error_message/1`

     * Call the `socket_connect/4` passing along socket params from client and
       keep the state of the returned `%Socket{}` to pass into dispatch.
     * Subscribe to the socket's `:id` on init and handle
       `%Phoenix.Socket.Broadcast{}` messages with the `"disconnect"` event
       and gracefully shutdown.


  See `Phoenix.Transports.WebSocket` for an example transport server implementation.


  ### Remote Client

  Synchronouse Replies and `ref`'s:

  Channels can reply, synchronously, to any `handle_in/3` event. To match pushes
  with replies, clients must include a unique `ref` with every message and the
  channel server will reply with a matching ref where the client and pick up the
  callback for the matching reply.

  Phoenix includes a JavaScript client for WebSocket and Longpolling support using JSON
  encodings.

  However, a client can be implemented for other protocols and encodings by
  abiding by the `Phoenix.Socket.Message` format

  See `web/static/js/phoenix.js` for an example transport client implementation.
  """

  use Behaviour
  require Logger
  alias Phoenix.Socket
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.Reply

  @doc """
  Provides a keyword list of default configuration for socket transports
  """
  defcallback default_config() :: list


  @doc """
  Calls the socket handler's `connect/2` callback and returns the result.

  If the connection was successful, generates `Phoenix.PubSub` topic
  from the `id/1` callback.
  """
  def socket_connect(endpoint, transport_mod, handler, params) do
    serializer  = Keyword.fetch!(handler.__transport__(transport_mod), :serializer)
    base_socket = %Socket{endpoint: endpoint,
                          transport: transport_mod,
                          handler: handler,
                          pubsub_server: endpoint.__pubsub_server__(),
                          serializer: serializer}

    case handler.connect(params, base_socket) do
      {:ok, socket} ->
        case handler.id(socket) do
          nil                   -> {:ok, socket}
          id when is_binary(id) -> {:ok, %Socket{socket | id: id}}
          _                     ->
          raise ArgumentError, """
          Expected #{inspect handler}.id/1 to return one of `nil | id :: String.t`
          """
        end

      :error -> :error

      _ -> raise ArgumentError, """
      Expected #{inspect handler}.connect/2 to return one of `{:ok, Socket.t} | :error`
      """
    end
  end

  @doc """
  Dispatches `%Phoenix.Socket.Message{}` to Channel. All serialized, remote client messages
  should be deserialized and forwarded through this function by adapters.

  The following return signatures must be handled by transport adapters:
    * `{:ok, socket_pid}` - Successful dispatch, with pid of new socket
    * `{:error, reason}` - Unauthorized or unmatched dispatch

  """
  def dispatch(%Message{} = msg, sockets, transport_pid, socket) do
    sockets
    |> HashDict.get(msg.topic)
    |> dispatch(msg, transport_pid, socket)
  end

  @doc """
  Dispatches `%Phoenix.Socket.Message{}` in response to a heartbeat message sent from the client.

  The Message format sent to phoenix requires the following key / values:

    * `topic` - The String value "phoenix"
    * `event` - The String value "heartbeat"
    * `payload` - An empty JSON message payload (`{}`)

  The server will respond to heartbeats with the same message
  """
  def dispatch(_, %{ref: ref, topic: "phoenix", event: "heartbeat"}, _transport_pid, _socket) do
    {:ok, %Reply{ref: ref, topic: "phoenix", status: :ok, payload: %{}}}
  end
  def dispatch(nil, %{event: "phx_join", topic: topic} = msg, transport_pid, base_socket) do
    case base_socket.handler.channel_for_topic(topic, base_socket.transport) do
      nil -> reply_ignore(msg, base_socket)

      channel ->
        socket = %Socket{base_socket |
                         transport_pid: transport_pid,
                         topic: topic,
                         channel: channel}

        log_info topic, fn ->
          "JOIN #{topic} to #{inspect(channel)}\n" <>
          "  Transport:  #{inspect socket.transport}\n" <>
          "  Parameters: #{inspect msg.payload}"
        end

        case Phoenix.Channel.Server.join(socket, msg.payload) do
          {:ok, response, pid} ->
            log_info topic, fn -> "Replied #{topic} :ok" end
            {:ok, pid, %Reply{ref: msg.ref, topic: topic, status: :ok, payload: response}}

          {:error, reason} ->
            log_info topic, fn -> "Replied #{topic} :error" end
            {:error, reason, %Reply{ref: msg.ref, topic: topic, status: :error, payload: reason}}
        end
    end
  end
  def dispatch(nil, msg, _transport_pid, socket) do
    reply_ignore(msg, socket)
  end
  def dispatch(socket_pid, %{event: "phx_leave", ref: ref}, _transport_pid,  _socket) do
    Phoenix.Channel.Server.leave(socket_pid, ref)
    :ok
  end
  def dispatch(socket_pid, msg, _transport_pid, _socket) do
    send(socket_pid, msg)
    :ok
  end

  defp log_info("phoenix" <> _, _func), do: :noop
  defp log_info(_topic, func), do: Logger.info(func)

  defp reply_ignore(msg, socket) do
    Logger.debug fn -> "Ignoring unmatched topic \"#{msg.topic}\" in #{inspect(socket.handler)}" end

    {:error, :unmatched_topic, %Reply{ref: msg.ref, topic: msg.topic,
                                      status: :error,
                                      payload: %{reason: "unmatched topic"}}}
  end

  @doc """
  Returns the `%Phoenix.Message{}` for a channel close event
  """
  def chan_close_message(topic) do
    %Message{topic: topic, event: "phx_close", payload: %{}}
  end

  @doc """
  Returns the `%Phoenix.Message{}` for a channel error event
  """
  def chan_error_message(topic) do
    %Message{topic: topic, event: "phx_error", payload: %{}}
  end

  @doc """
  Checks the Origin request header against the list of allowed origins
  configured on the socket's transport config. If the Origin
  header matches the allowed origins, no Origin header was sent or no origins
  configured it will return the given `Plug.Conn`. Otherwise a 403 Forbidden
  response will be send and the connection halted.
  """
  def check_origin(conn, allowed_origins, opts \\ []) do
    import Plug.Conn
    origin = get_req_header(conn, "origin") |> List.first
    send = opts[:send] || &send_resp(&1)

    if origin_allowed?(origin, allowed_origins) do
      conn
    else
      resp(conn, :forbidden, "")
      |> send.()
      |> halt()
    end
  end

  defp origin_allowed?(nil, _) do
    true
  end
  defp origin_allowed?(_, nil) do
    true
  end
  defp origin_allowed?(origin, allowed_origins) do
    origin = URI.parse(origin)

    Enum.any?(allowed_origins, fn allowed ->
      allowed = URI.parse(allowed)

      compare?(origin.scheme, allowed.scheme) and
      compare?(origin.port, allowed.port) and
      compare?(origin.host, allowed.host)
    end)
  end

  defp compare?(nil, _), do: true
  defp compare?(_, nil), do: true
  defp compare?(x, y),   do: x == y
end
