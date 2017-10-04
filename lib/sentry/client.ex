defmodule Sentry.Client do
  @behaviour Sentry.HTTPClient

  @moduledoc ~S"""
  This module is the default client for sending an event to Sentry via HTTP.

  It makes use of `Task.Supervisor` to allow sending tasks synchronously or asynchronously, and defaulting to asynchronous. See `Sentry.Client.send_event/2` for more information.

  ### Configuration

  * `:before_send_event` - allows performing operations on the event before
    it is sent.  Accepts an anonymous function or a {module, function} tuple, and
    the event will be passed as the only argument.

  * `:after_send_event` - callback that is called after attempting to send an event.
    Accepts an anonymous function or a {module, function} tuple. The result of the HTTP call as well as the event will be passed as arguments.
    The return value of the callback is not returned.

  Example configuration of putting Logger metadata in the extra context:

      config :sentry,
        before_send_event: fn(event) ->
          metadata = Map.new(Logger.metadata)
          %{event | extra: Map.merge(event.extra, metadata)}
        end,

        after_send_event: fn(event, result) ->
          case result do
            {:ok, id} ->
              Logger.info("Successfully sent event!")
            _ ->
              Logger.info(fn -> "Did not successfully send event! #{inspect(event)}" end)
          end
        end
  """

  alias Sentry.{Event, Util, Config}

  require Logger

  @type get_dsn :: {String.t, String.t, Integer.t} | :error
  @sentry_version 5
  @max_attempts 4
  @hackney_pool_name :sentry_pool

  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config[:version]}")
  end

  @doc """
  Attempts to send the event to the Sentry API up to 4 times with exponential backoff.

  The event is dropped if it all retries fail.

  ### Options
  * `:result` - Allows specifying how the result should be returned. Options include `:sync`, `:none`, and `:async`.  `:sync` will make the API call synchronously, and return `{:ok, event_id}` if successful.  `:none` sends the event from an unlinked child process under `Sentry.TaskSupervisor` and will return `{:ok, ""}` regardless of the result.  `:async` will start an unlinked task and return a tuple of `{:ok, Task.t}` on success where the Task can be awaited upon to receive the result asynchronously.  When used in an OTP behaviour like GenServer, the task will send a message that needs to be matched with `GenServer.handle_info/2`.  See `Task.Supervisor.async_nolink/2` for more information.  `:async` is the default.
  * `:sample_rate` - The sampling factor to apply to events.  A value of 0.0 will deny sending any events, and a value of 1.0 will send 100% of events.
  """
  @spec send_event(Event.t) :: {:ok, Task.t | String.t} | :error | :unsampled
  def send_event(%Event{} = event, opts \\ []) do
    result = Keyword.get(opts, :result, :async)
    sample_rate = Keyword.get(opts, :sample_rate) || Config.sample_rate()

    event = maybe_call_before_send_event(event)

    if sample_event?(sample_rate) do
      encode_and_send(event, result)
    else
      :unsampled
    end
  end

  defp encode_and_send(event, result) do
    case Poison.encode(event) do
      {:ok, body} ->
        do_send_event(event, body, result)
      {:error, error} ->
        log_api_error("Unable to encode Sentry error - #{inspect(error)}")
        :error
    end
  end

  defp do_send_event(event, body, :async) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} ->
        {:ok, Task.Supervisor.async_nolink(Sentry.TaskSupervisor, fn ->
          try_request(:post, endpoint, auth_headers, body)
          |> maybe_call_after_send_event(event)
        end)}
      _ ->
        :error
    end
  end

  defp do_send_event(event, body, :sync) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} ->
        try_request(:post, endpoint, auth_headers, body)
        |> maybe_call_after_send_event(event)
      _ ->
        :error
    end
  end

  defp do_send_event(event, body, :none) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} ->
        Task.Supervisor.start_child(Sentry.TaskSupervisor, fn ->
          try_request(:post, endpoint, auth_headers, body)
          |> maybe_call_after_send_event(event)
        end)

        {:ok, ""}
      _ ->
        :error
    end
  end

  defp try_request(method, url, headers, body, current_attempt \\ 1)
  defp try_request(_, _, _, _, current_attempt)
    when current_attempt > @max_attempts, do: :error
  defp try_request(method, url, headers, body, current_attempt) do
    case request(method, url, headers, body) do
      {:ok, id} -> {:ok, id}
      _ ->
        sleep(current_attempt)
        try_request(method, url, headers, body, current_attempt + 1)
    end
  end

  @doc """
  Makes the HTTP request to Sentry using hackney.

  Hackney options can be set via the `hackney_opts` configuration option.
  """
  def request(method, url, headers, body) do
    hackney_opts = Config.hackney_opts()
                   |> Keyword.put_new(:pool, @hackney_pool_name)
    with {:ok, 200, _, client} <- :hackney.request(method, url, headers, body, hackney_opts),
         {:ok, body} <- :hackney.body(client),
         {:ok, json} <- Poison.decode(body) do
      {:ok, Map.get(json, "id")}
    else
      {:ok, status, headers, client} ->
        :hackney.skip_body(client)
        error_header = :proplists.get_value("X-Sentry-Error", headers, "")
        log_api_error("#{body}\nReceived #{status} from Sentry server: #{error_header}")
        :error
      _ ->
        log_api_error(body)
        :error
    end
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t, String.t) :: String.t
  def authorization_header(public_key, secret_key) do
    timestamp = Util.unix_timestamp()
    data = [
      sentry_version: @sentry_version,
      sentry_client: @sentry_client,
      sentry_timestamp: timestamp,
      sentry_key: public_key,
      sentry_secret: secret_key
    ]
    query = data
            |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
            |> Enum.join(", ")
    "Sentry " <> query
  end

  defp authorization_headers(public_key, secret_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, secret_key)}
    ]
  end

  @doc """
  Get a Sentry DSN which is simply a URI.

  {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
  """
  @spec get_dsn :: get_dsn
  def get_dsn do
    dsn = Config.dsn()
    with %URI{userinfo: userinfo, host: host, port: port, path: path, scheme: protocol} when is_binary(path) <- URI.parse(dsn),
         [public_key, secret_key] <- String.split(userinfo, ":", parts: 2),
         [_, binary_project_id] <- String.split(path, "/"),
         {project_id, ""} <- Integer.parse(binary_project_id),
         endpoint <- "#{protocol}://#{host}:#{port}/api/#{project_id}/store/"
    do
      {endpoint, public_key, secret_key}
    else _ ->
      log_api_error("Cannot send event because of invalid DSN")
      :error
    end
  end

  def maybe_call_after_send_event(result, event) do
    case Config.after_send_event() do
      function when is_function(function, 2) ->
        function.(event, result)
      {module, function} ->
        apply(module, function, [event, result])
      nil ->
        nil
      _ ->
        raise ArgumentError, message: ":after_send_event must be an anonymous function or a {Module, Function} tuple"
    end

    result
  end

  def maybe_call_before_send_event(event) do
    case Config.before_send_event do
      function when is_function(function, 1) ->
        function.(event)
      {module, function} ->
        apply(module, function, [event])
      nil ->
        event
      _ ->
        raise ArgumentError, message: ":before_send_event must be an anonymous function or a {Module, Function} tuple"
    end
  end

  def hackney_pool_name do
    @hackney_pool_name
  end

  defp get_headers_and_endpoint do
    case get_dsn() do
      {endpoint, public_key, secret_key} ->
         {endpoint, authorization_headers(public_key, secret_key)}
      _ ->
        :error
    end
  end

  defp log_api_error(body) do
    Logger.warn(fn ->
      ["Failed to send Sentry event.", ?\n, body]
    end)
  end

  defp sleep(attempt_number) do
    # sleep 2^n seconds
    :math.pow(2, attempt_number)
    |> Kernel.*(1000)
    |> Kernel.round()
    |> :timer.sleep()
  end

  defp sample_event?(1), do: true
  defp sample_event?(1.0), do: true
  defp sample_event?(0), do: false
  defp sample_event?(0.0), do: false
  defp sample_event?(sample_rate) do
    :rand.uniform < sample_rate
  end
end
