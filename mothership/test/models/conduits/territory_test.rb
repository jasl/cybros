require "test_helper"

class Conduits::TerritoryTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @territory = Conduits::Territory.create!(account: @account, name: "test-territory")
  end

  # State machine transitions

  test "initial state is pending" do
    assert @territory.pending?
  end

  test "activate transitions from pending to online" do
    @territory.activate!
    assert @territory.online?
  end

  test "go_offline transitions from online to offline" do
    @territory.activate!
    @territory.go_offline!
    assert @territory.offline?
  end

  test "go_online transitions from offline to online" do
    @territory.activate!
    @territory.go_offline!
    @territory.go_online!
    assert @territory.online?
  end

  test "decommission from online" do
    @territory.activate!
    @territory.decommission!
    assert @territory.decommissioned?
  end

  # record_heartbeat!

  test "record_heartbeat! updates last_heartbeat_at" do
    @territory.activate!
    @territory.record_heartbeat!
    assert @territory.last_heartbeat_at.present?
  end

  test "record_heartbeat! stores capacity" do
    @territory.activate!
    capacity = { "sandbox_health" => { "host" => { "healthy" => true } } }
    @territory.record_heartbeat!(capacity: capacity)
    assert_equal capacity, @territory.capacity
  end

  test "record_heartbeat! brings offline territory back online" do
    @territory.activate!
    @territory.go_offline!
    assert @territory.offline?
    @territory.record_heartbeat!
    assert @territory.online?
  end

  test "record_heartbeat! does not auto-activate pending territory" do
    assert @territory.pending?
    @territory.record_heartbeat!
    # go_online only transitions from offline, not pending
    assert @territory.pending?
  end

  # heartbeat_stale?

  test "heartbeat_stale? returns true when no heartbeat" do
    assert @territory.heartbeat_stale?
  end

  test "heartbeat_stale? returns false after recent heartbeat" do
    @territory.activate!
    @territory.record_heartbeat!
    assert_not @territory.heartbeat_stale?
  end

  # sandbox_healthy?

  test "sandbox_healthy? returns true when no capacity data" do
    assert @territory.sandbox_healthy?("host")
    assert @territory.sandbox_healthy?("untrusted")
    assert @territory.sandbox_healthy?("trusted")
  end

  test "sandbox_healthy? returns true when no sandbox_health key" do
    @territory.capacity = { "supported_profiles" => %w[host untrusted] }
    assert @territory.sandbox_healthy?("host")
  end

  test "sandbox_healthy? returns true for healthy host driver" do
    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true, "details" => { "driver" => "host" } }
      }
    }
    assert @territory.sandbox_healthy?("host")
  end

  test "sandbox_healthy? returns false for unhealthy host driver" do
    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => false, "details" => { "error" => "test" } }
      }
    }
    assert_not @territory.sandbox_healthy?("host")
  end

  test "sandbox_healthy? maps untrusted to bwrap by default" do
    @territory.capacity = {
      "sandbox_health" => {
        "bwrap" => { "healthy" => true }
      }
    }
    assert @territory.sandbox_healthy?("untrusted")
  end

  test "sandbox_healthy? uses untrusted_driver from heartbeat when set to firecracker" do
    @territory.capacity = {
      "sandbox_health" => {
        "bwrap" => { "healthy" => true },
        "firecracker" => { "healthy" => false, "details" => { "error" => "no kvm" } }
      },
      "untrusted_driver" => "firecracker"
    }
    # Must check firecracker (the actual driver), not bwrap
    assert_not @territory.sandbox_healthy?("untrusted")
  end

  test "sandbox_healthy? uses untrusted_driver from heartbeat when set to bwrap" do
    @territory.capacity = {
      "sandbox_health" => {
        "bwrap" => { "healthy" => false, "details" => { "error" => "namespace test failed" } },
        "firecracker" => { "healthy" => true }
      },
      "untrusted_driver" => "bwrap"
    }
    # Must check bwrap (the actual driver), not firecracker
    assert_not @territory.sandbox_healthy?("untrusted")
  end

  test "sandbox_healthy? maps trusted profile to container driver" do
    @territory.capacity = {
      "sandbox_health" => {
        "container" => { "healthy" => true }
      }
    }
    assert @territory.sandbox_healthy?("trusted")
  end

  test "sandbox_healthy? returns true when driver not in health data" do
    # Trusted maps to container, but container not reported — default true
    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true }
      }
    }
    assert @territory.sandbox_healthy?("trusted")
  end

  test "sandbox_healthy? handles mixed healthy and unhealthy" do
    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true },
        "bwrap" => { "healthy" => false, "details" => { "error" => "namespace failed" } },
        "container" => { "healthy" => true }
      },
      "untrusted_driver" => "bwrap"
    }
    assert @territory.sandbox_healthy?("host")
    assert_not @territory.sandbox_healthy?("untrusted")
    assert @territory.sandbox_healthy?("trusted")
  end

  test "sandbox_healthy? accepts symbol profile" do
    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true }
      }
    }
    assert @territory.sandbox_healthy?(:host)
  end

  test "sandbox_healthy? handles darwin-automation profile" do
    @territory.capacity = {
      "sandbox_health" => {
        "darwin-automation" => { "healthy" => false }
      }
    }
    assert_not @territory.sandbox_healthy?("darwin-automation")
  end
end
