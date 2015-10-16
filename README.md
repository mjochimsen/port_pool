PortPool
========

The PortPool application provides a means to keep a pool of TCP port numbers
which can be shared amongst multiple processes. This permits multiple
processes to make use of a limited set of port numbers without colliding.

Installation
------------

The application can be installed by adding port_pool to your list of
dependencies in `mix.exs`:

    def deps do
      [{:port_pool, github: "mjochimsen/port_pool"}]
    end

The application does not need to be started, so there is no need to include it
under the `:applications` key for your application.

Usage
-----

In order to use a `PortPool` the `PortPool` process will need to be started.
This is done using `PortPool.start_link/1` which takes a list or range of port
numbers as the contents of the pool.

Once started, port numbers may be bound to a process using `PortPool.bind/1`.
This will bind a port number to the caller and return it for use. If the pool
of available port numbers is empty, then the caller will block until a port
number becomes available.

When a process is finished using a port number, it can release it back to the
pool by calling `PortPool.release/1`. This will allow another process to
`bind/1` it and use it in turn.

Should a process need to transfer ownership of a port number, it can use the
`PortPool.rebind/2` function, which will notify the pool that the owership has
changed to a different process.

The `PortPool` process can be stopped using `PortPool.stop/0` function. The
ownership of any ports which are still bound will be forgotten as a result of
calling this function.
