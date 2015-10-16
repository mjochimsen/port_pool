defmodule PortPoolTest do

  @ports 5000..5001
  @port_count Enum.count(@ports)

  use ExUnit.Case, async: false

  @moduletag timeout: 1000

  setup_all do
    Application.stop(:mock_server)
    on_exit(fn ->
      Application.start(:mock_server)
    end)
    :ok
  end

  test "starting and stopping the port pool" do
    # Test creating and stopping the pool with a list of port numbers
    assert {:ok, pool} = PortPool.start_link([5000, 5001, 5002, 5003, 5004])
    assert is_pid(pool)
    assert PortPool.debug_count() == 5
    assert :ok = PortPool.stop()

    # Again, with a single port number
    assert {:ok, pool} = PortPool.start_link(5000)
    assert is_pid(pool)
    assert PortPool.debug_count() == 1
    assert :ok = PortPool.stop()

    # Again, with a range of port numbers
    assert {:ok, pool} = PortPool.start_link(5000..5004)
    assert is_pid(pool)
    assert PortPool.debug_count() == 5
    assert :ok = PortPool.stop()

    # Again, with a list of port number ranges
    assert {:ok, pool} = PortPool.start_link([5000..5002, 5004..5006])
    assert is_pid(pool)
    assert PortPool.debug_count() == 6
    assert :ok = PortPool.stop()

    # Again, with a mixed list of port numbers and ranges of port numbers
    assert {:ok, pool} = PortPool.start_link([5000..5002, 5005, 5007..5009])
    assert is_pid(pool)
    assert PortPool.debug_count() == 7
    assert :ok = PortPool.stop()

    # Again, with duplicate port numbers
    assert {:ok, pool} = PortPool.start_link([5000, 5001, 5002, 5001])
    assert is_pid(pool)
    assert PortPool.debug_count() == 3
    assert :ok = PortPool.stop()

    # Again, with overlapping ranges
    assert {:ok, pool} = PortPool.start_link([5000..5004, 5002..5006])
    assert is_pid(pool)
    assert PortPool.debug_count() == 7
    assert :ok = PortPool.stop()
  end

  test "binding and releasing a port number from the pool" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Check the count of free port numbers in the pool
    assert PortPool.debug_count() == @port_count

    # Try and get a port number
    assert {:ok, port_number} = PortPool.bind()
    assert port_number in @ports

    # Check the free port number count again
    assert PortPool.debug_count() == @port_count - 1

    # Try and release the port number
    assert :ok == PortPool.release(port_number)

    # Check the free port number count
    assert PortPool.debug_count() == @port_count

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "binding port numbers from an empty pool" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Bind all the port numbers in the pool
    assert @port_count == PortPool.debug_count()
    for _ <- @ports do
      assert {:ok, _port_number} = PortPool.bind()
    end
    assert 0 == PortPool.debug_count()

    assert {:error, :empty} = PortPool.bind(100)

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "releasing unbound port numbers" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Attempt to release an unbound port number
    port_number.._ = @ports
    assert {:error, :unbound} = PortPool.release(port_number)

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "releasing bound port numbers with a different process" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Bind a port number
    assert {:ok, port_number} = PortPool.bind()

    # Try and release the port number in a different process
    {pid, ref} = spawn_monitor(fn ->
      assert {:error, :not_owner} = PortPool.release(port_number)
    end)
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> true
    end

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "rebinding a port number in the pool" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Bind a port number
    {:ok, port_number} = PortPool.bind()

    # Rebind the port to a new process, which will in turn release it.
    {pid, ref} = spawn_monitor(fn ->
      receive do
        {:release, port_number} -> assert :ok == PortPool.release(port_number)
      end
    end)
    assert PortPool.debug_count() == @port_count - 1
    assert :ok == PortPool.rebind(port_number, pid)
    assert PortPool.debug_count() == @port_count - 1
    send(pid, {:release, port_number})
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> true
    end
    assert PortPool.debug_count() == @port_count

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "rebinding an unbound port number" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Attempt to rebind an unbound port number
    {pid, ref} = spawn_monitor(fn ->
      receive do
        :stop -> true
      end
    end)
    port_number.._ = @ports
    assert {:error, :unbound} = PortPool.rebind(port_number, pid)
    send(pid, :stop)
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> true
    end

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "rebinding a port number from a process which is not the owner" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Bind a port number
    {:ok, port_number} = PortPool.bind()

    # Attempt to rebind the port number in a different process
    {pid, ref} = spawn_monitor(fn ->
      assert {:error, :not_owner} = PortPool.rebind(port_number, self)
    end)
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> true
    end

    # Stop the pool
    :ok = PortPool.stop()
  end

  test "overusing the listener pool" do
    # Start the pool
    {:ok, _pool} = PortPool.start_link(@ports)

    # Spawn twice as many 'workers' as available port numbers
    monitors =
      for _i <- 1..2 do
        for _j <- @ports do
          spawn_monitor(__MODULE__, :faux_worker, [self])
        end
      end
      |> List.flatten
    server_count = Enum.count(monitors)

    # Wait for all the 'workers' to start
    for {pid, _ref} <- monitors do
      receive do
        {:start, ^pid} -> pid
      after 10 * server_count ->
        flunk "should have started all mock workers by now"
      end
    end

    # Make sure that we've drained the listener pool.
    assert 0 == PortPool.debug_count()

    # Wait for the 'workers' to finish up
    for {pid, ref} <- monitors do
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> pid
      after 20 * server_count ->
        flunk "should have completed all mock workers by now"
      end
    end

    # Double check that all of our monitored pids stopped
    Enum.each(monitors, fn {pid, _ref} ->
      refute Process.alive?(pid)
    end)

    # Make sure the pool is full again.
    assert @port_count == PortPool.debug_count()

    # Stop the pool
    :ok = PortPool.stop()
  end

  # Synthesize the bind/release process of a port number with some 'work' done
  # while the port number is bound. Our 'work' will take between 5 and 20ms,
  # which should cause pressure on the pool without excessively delaying our
  # tests.
  def faux_worker(test) do
    send(test, {:start, self})
    assert {:ok, port_number} = PortPool.bind()
    assert port_number in @ports
    :crypto.rand_uniform(5, 20) |> :timer.sleep()
    assert :ok == PortPool.release(port_number)
  end

end
