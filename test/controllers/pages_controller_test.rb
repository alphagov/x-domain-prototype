require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "should get jugglingLicence" do
    get pages_jugglingLicence_url
    assert_response :success
  end
end
