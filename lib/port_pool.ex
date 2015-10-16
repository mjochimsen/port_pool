defmodule PortPool do

  @moduledoc """
  `PortPool` is a pool of TCP port numbers. We include methods to bind and
  release these numbers for use by network servers.

  The primary purpose of this module it to allow a pool of port numbers to be
  shared by a number of processes without multiple processes attempting to use
  the same port number. Numbers are bound to a process using `bind/1`, and
  released by the same process using `release/1`. If ownership of the port
  number is transferred to a different process, then the pool should be informed
  of the change in ownership via `rebind/2`.
  """

  # --- Constants ---

  @retry_interval 20

  # --- Types ---

  @type port_number :: :inet.port_number
  @type port_number_range :: Range.t(port_number, port_number)
  @type on_bind :: {:ok, port_number} | {:error, :empty}
  @type on_rebind :: :ok | {:error, :unbound | :not_owner}
  @type on_release :: :ok | {:error, :unbound | :not_owner}
  @typep owner :: pid
  @typep pool_state :: {[port_number], [{port_number, owner}]}
  @typep on_count_call :: {:reply, non_neg_integer, pool_state}
  @typep on_bind_call :: {:noreply, pool_state}
  @typep on_rebind_call :: {:reply, on_rebind, pool_state}
  @typep on_release_call :: {:reply, on_release, pool_state}

  # --- API ---

  @doc """
  Start the pool process using a list of `port_numbers`. The `port_numbers` list
  can contain individual port numbers or ranges of port numbers. Alternately, a
  single range or even a single port number may be specified. The pool will be
  initialized to contain all the port numbers in the pool in a free (unbound)
  state.
  """
  @spec start_link([port_number | port_number_range] |
                   port_number_range |
                   port_number) :: GenServer.on_start
  def start_link(port_numbers) when is_list(port_numbers) do
    GenServer.start_link(__MODULE__, port_numbers, name: __MODULE__)
  end
  def start_link(%Range{} = port_range) do
    start_link([port_range])
  end
  def start_link(port_number) when is_integer(port_number) do
    start_link([port_number])
  end
  def start_link(_), do: {:error, :badarg}

  @doc """
  Stop the port pool.
  """
  @spec stop() :: :ok
  def stop() do
    :gen_server.stop(__MODULE__)
  end

  @doc """
  Bind a port number in the pool to a process. This will return
  `{:ok, port_number}`, which number will remain bound to the calling process
  until it is released by that process with a call to `release/1`.  The port
  number can be used by the caller in any way they would like without having to
  worry about a different caller using it.

  If no port number is available in the pool, then the caller will block for up
  to `timeout` milliseconds. If during this time a port number becomes
  available, then it will be returned as above. If no port number becomes
  available, then `{:error, :empty}` is returned. If no timeout is desired, then
  `:infinity` may be specified as the timeout (default).
  """
  @spec bind(timeout) :: on_bind
  def bind(timeout \\ :infinity) when timeout >= 0 or timeout == :infinity do
    GenServer.cast(__MODULE__, {:bind, self, timeout})
    receive do
      {__MODULE__, :bound, port_number} -> {:ok, port_number}
      {__MODULE__, :empty} -> {:error, :empty}
    end
  end

  @doc """
  Changes the process which has bound the `port_number` to `new_owner`. This is
  useful if the ownership of the `port_number` needs to be passed to a different
  process. The new process is responsible for releasing the `port_number` when
  it is done with it (or re-binding it to yet another process).

  If the `port_number` is not bound, then `{:error, :unbound}` is returned. If
  the `port_number` is not owned by the calling process then
  `{:error, :not_owner}` is returned. Otherwise `:ok` is returned.
  """
  @spec rebind(port_number, pid) :: on_rebind
  def rebind(port_number, new_owner) when port_number in 0..65535 and
                                          is_pid(new_owner) do
    GenServer.call(__MODULE__, {:rebind, port_number, self, new_owner})
  end

  @doc """
  Release the given `port_number`. The `port_number` must be released by the
  process which owns it, either the binding process or the process ownership
  was transferred to using `rebind/2`. Once released, the `port_number` is
  returned to the pool and may be bound to a new owner.

  If the `port_number` is not bound, then `{:error, :unbound}` is returned. If
  the `port_number` is not owned by the calling process then
  `{:error, :not_owner}` is returned. Otherwise `:ok` is returned.
  """
  @spec release(port_number) :: :ok
  def release(port_number) when port_number in 0..65535 do
    GenServer.call(__MODULE__, {:release, port_number, self})
  end

  @doc false
  # Get a count of unbound port numbers. This is used for testing.
  @spec debug_count() :: non_neg_integer
  def debug_count() do
    GenServer.call(__MODULE__, :count)
  end

  # --- GenServer callbacks ---

  use GenServer

  @doc false
  @spec init([port_number]) :: {:ok, pool_state}
  def init(port_numbers) do
    {:ok, {_expand_port_number_list(port_numbers), []}}
  end

  @doc false
  @spec handle_cast({:bind, owner, timeout}, pool_state) :: on_bind_call
  def handle_cast({:bind, owner, 0}, {[], bound_pool}) do
    send(owner, {__MODULE__, :empty})
    {:noreply, {[], bound_pool}}
  end
  def handle_cast({:bind, owner, timeout}, {[], bound_pool}) do
    callback = [__MODULE__, {:bind, owner, _update_timeout(timeout)}]
    {:ok, _} = :timer.apply_after(@retry_interval, GenServer, :cast, callback)
    {:noreply, {[], bound_pool}}
  end
  def handle_cast({:bind, owner, _timeout},
                  {[port_number | free_pool], bound_pool}) do
    send(owner, {__MODULE__, :bound, port_number})
    {:noreply, {free_pool, [{port_number, owner} | bound_pool]}}
  end

  @doc false
  @spec handle_call({:rebind, port_number, owner, owner}, term,
                    pool_state) :: on_rebind_call
  def handle_call({:rebind, port_number, old_owner, new_owner}, _from, pool) do
    {free_pool, bound_pool} = pool
    index = Enum.find_index(bound_pool, _match_port_number(port_number))
    if index do
      case Enum.at(bound_pool, index) do
        {^port_number, ^old_owner} ->
          bound_pool = List.replace_at(bound_pool, index,
                                       {port_number, new_owner})
          {:reply, :ok, {free_pool, bound_pool}}
        {^port_number, _owner} ->
          {:reply, {:error, :not_owner}, pool}
      end
    else
      {:reply, {:error, :unbound}, pool}
    end
  end

  @doc false
  @spec handle_call({:release, port_number, owner}, term,
                    pool_state) :: on_release_call
  def handle_call({:release, port_number, owner}, _from, pool) do
    {free_pool, bound_pool} = pool
    bound_port = Enum.find(bound_pool, _match_port_number(port_number))
    if bound_port do
      if {port_number, owner} == bound_port do
        bound_pool = List.delete(bound_pool, {port_number, owner})
        {:reply, :ok, {[port_number | free_pool], bound_pool}}
      else
        {:reply, {:error, :not_owner}, pool}
      end
    else
      {:reply, {:error, :unbound}, pool}
    end
  end

  @doc false
  @spec handle_call(:count, term, pool_state) :: on_count_call
  def handle_call(:count, _from, pool) do
    {free_pool, _bound_pool} = pool
    count = Enum.count(free_pool)
    {:reply, count, pool}
  end

  # --- Helpers ---

  defp _expand_port_number_list(port_list, working_list \\ [])
  defp _expand_port_number_list([], ports) do
    Enum.uniq(ports)
  end
  defp _expand_port_number_list([%Range{} = port_range | rest], ports) do
    _expand_port_number_list(rest, Enum.into(port_range, ports))
  end
  defp _expand_port_number_list([port | rest], ports) when is_integer(port) do
    _expand_port_number_list(rest, [port | ports])
  end

  defp _match_port_number(port_number) do
    fn {portnum, _owner} -> port_number == portnum end
  end

  defp _update_timeout(:infinity), do: :infinity
  defp _update_timeout(timeout) when timeout < @retry_interval, do: 0
  defp _update_timeout(timeout), do: timeout - @retry_interval

end
