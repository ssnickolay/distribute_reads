require_relative "test_helper"

class DistributeReadsTest < Minitest::Test
  def setup
    # reset context
    Makara::Cache.store = :memory
    Makara::Context.set_current(Makara::Context.generate)
  end

  def test_default
    assert_primary
    assert_cache_size 0
  end

  def test_default_to_primary
    without_default_to_primary do
      assert_replica
      insert_value
      assert_primary
      assert_cache_size 1
    end
  end

  def test_distribute_reads
    insert_value
    assert_primary
    distribute_reads do
      assert_replica
      insert_value
      assert_replica
    end
    assert_cache_size 0
  end

  def test_distribute_reads_default_to_primary_false
    without_default_to_primary do
      distribute_reads do
        assert_replica
        insert_value
        assert_replica
      end
      assert_primary
      assert_cache_size 1
    end
  end

  def test_distribute_reads_transaction
    distribute_reads do
      ActiveRecord::Base.transaction do
        assert_primary
      end
    end
    assert_cache_size 0
  end

  def test_max_lag
    with_lag(2) do
      assert_raises DistributeReads::TooMuchLag do
        distribute_reads(max_lag: 1) do
          assert_replica
        end
      end
    end
  end

  def test_max_lag_under
    distribute_reads(max_lag: 1) do
      assert_replica
    end
  end

  def test_max_lag_failover
    with_lag(2) do
      distribute_reads(max_lag: 1, lag_failover: true) do
        assert_primary
      end
    end
  end

  def test_active_job
    TestJob.perform_now
    assert_equal "replica", $current_database
  end

  def test_missing_block
    error = assert_raises(ArgumentError) { distribute_reads }
    assert_equal "Missing block", error.message
  end

  def test_relation
    assert_output(nil, /\A\[distribute_reads\]/) do
      distribute_reads do
        User.all
      end
    end
  end

  def test_failover_true
    with_replicas_blacklisted do
      distribute_reads do
        assert_primary
      end
    end
  end

  def test_failover_false
    with_replicas_blacklisted do
      assert_raises DistributeReads::NoReplicasAvailable do
        distribute_reads(failover: false) do
          assert_replica
        end
      end
    end
  end

  def test_default_to_primary_false_active_job
    without_default_to_primary do
      ReadWriteJob.perform_now
      assert_equal "replica", $current_database

      ReadWriteJob.perform_now
      assert_equal "replica", $current_database
    end
  end

  private

  def without_default_to_primary
    DistributeReads.default_to_primary = false
    yield
  ensure
    DistributeReads.default_to_primary = true
  end

  def with_replicas_blacklisted
    ActiveRecord::Base.connection.instance_variable_get(:@slave_pool).stub(:completely_blacklisted?, true) do
      yield
    end
  end

  def with_lag(lag)
    ActiveRecord::Base.connection.instance_variable_get(:@slave_pool).connections.first.stub(:execute, [{"lag" => lag}]) do
      yield
    end
  end

  def assert_primary
    assert_equal "primary", current_database
  end

  def assert_replica
    assert_equal "replica", current_database
  end

  def assert_cache_size(value)
    assert_equal value, Makara::Cache.send(:store).instance_variable_get(:@data).size
  end
end
