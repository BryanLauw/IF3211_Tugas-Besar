require "test_helper"

class CalculatorControllerTest < ActionDispatch::IntegrationTest
  test "should get genotype" do
    get calculator_genotype_url
    assert_response :success
  end
end
