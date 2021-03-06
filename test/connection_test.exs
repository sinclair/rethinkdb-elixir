defmodule ConnectionTest do
  use ExUnit.Case, async: true
  import Supervisor.Spec
  use RethinkDB.Connection
  import RethinkDB.Query

  require Logger

  test "Connections can be supervised" do
    children = [worker(RethinkDB.Connection, [])]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert Supervisor.count_children(sup) == %{active: 1, specs: 1, supervisors: 0, workers: 1}
    Process.exit(sup, :kill)
  end

  test "using Connection works with supervision" do
    children = [worker(__MODULE__, [])]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert Supervisor.count_children(sup) == %{active: 1, specs: 1, supervisors: 0, workers: 1}
    Process.exit(sup, :kill)
  end

  test "using Connection will raise if name is provided" do
    assert_raise ArgumentError, fn ->
      start_link(name: :test)
    end
  end

  test "reconnects if initial connect fails" do
    {:ok, c} = start_link([port: 28014])
    Process.unlink(c)
    %RethinkDB.Exception.ConnectionClosed{} = table_list |> run
    conn = FlakyConnection.start('localhost', 28015, 28014)
    :timer.sleep(1000)
    %RethinkDB.Record{} = RethinkDB.Query.table_list |> run
    ref = Process.monitor(c)
    FlakyConnection.stop(conn)
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  test "replies to pending queries on disconnect" do
    conn = FlakyConnection.start('localhost', 28015)
    {:ok, c} = start_link([port: conn.port])
    Process.unlink(c)
    table = "foo_flaky_test"
    RethinkDB.Query.table_create(table)|> run
    on_exit fn ->
      start_link
      :timer.sleep(100)
      RethinkDB.Query.table_drop(table) |> run
      GenServer.cast(__MODULE__, :stop)
    end
    table(table) |> index_wait |> run
    change_feed = table(table) |> changes |> run
    task = Task.async fn ->
      RethinkDB.Connection.next change_feed
    end
    :timer.sleep(100)
    ref = Process.monitor(c)
    FlakyConnection.stop(conn)
    %RethinkDB.Exception.ConnectionClosed{} = Task.await(task)
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  test "supervised connection restarts on disconnect" do
    conn = FlakyConnection.start('localhost', 28015)
    children = [worker(__MODULE__, [[port: conn.port]])]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert Supervisor.count_children(sup) == %{active: 1, specs: 1, supervisors: 0, workers: 1}

    FlakyConnection.stop(conn)
    :timer.sleep(100) # this is a band-aid for a race condition in this test
   
    assert Supervisor.count_children(sup) == %{active: 1, specs: 1, supervisors: 0, workers: 1}

    Process.exit(sup, :normal)
  end

  test "connection accepts default db" do
    {:ok, c} = RethinkDB.Connection.start_link([db: "new_test"])
    db_create("new_test") |> RethinkDB.run(c)
    db("new_test") |> table_create("new_test_table") |> RethinkDB.run(c)
    %{data: data} = table_list |> RethinkDB.run(c)
    assert data == ["new_test_table"]
  end

  test "sync connection" do
    {:error, :econnrefused} = Connection.start(RethinkDB.Connection, [port: 28014, sync_connect: true])
    conn = FlakyConnection.start('localhost', 28015, 28014)
    {:ok, pid} = Connection.start(RethinkDB.Connection, [port: 28014, sync_connect: true])
    FlakyConnection.stop(conn)
    Process.exit(pid, :shutdown)
  end
end
