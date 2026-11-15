require "test_helper"
require "timeout"

class DriverWorkSnapshotConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a company write lock does not block a conditional work read" do
    user = users(:driver)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.post "/session", params: { email_address: user.email_address, password: "Repartos-test-2026" }
    assert browser.response.redirect?
    browser.get "/repartidor/api/v1/work"
    assert_equal 200, browser.response.status
    etag = browser.response.headers.fetch("ETag")
    locked, release = Queue.new, Queue.new
    writer = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Company.find(user.company_id).with_lock { locked << true; release.pop }
      end
    end
    locked.pop
    Timeout.timeout(10) { browser.get "/repartidor/api/v1/work", headers: { "If-None-Match" => etag } }
    assert_equal 304, browser.response.status
  ensure
    release << true if release
    writer&.join
  end

  test "read snapshot remains coherent when planning is committed between queries" do
    assert_equal 0, ApplicationRecord.connection.open_transactions
    user = users(:driver)
    session = user.sessions.create!
    before = companies(:one).name
    Current.session = session
    Company.uncached do
      DriverWorkSnapshot.consistent_read do
        assert_equal before, Company.where(id: user.company_id).pick(:name)
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Company.find(user.company_id).update!(name: "Concurrent revision")
          end
        end.value
        assert_equal before, Company.where(id: user.company_id).pick(:name)
      end
      assert_equal "Concurrent revision", Company.where(id: user.company_id).pick(:name)
    end
  ensure
    Current.reset
  end
end
