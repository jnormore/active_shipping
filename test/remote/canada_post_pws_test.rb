require 'test_helper'

class CanadaPostPWSTest < Test::Unit::TestCase
  
  def setup

    login = fixtures(:canada_post_pws)
    
    # 100 grams, 93 cm long, 10 cm diameter, cylinders have different volume calculations
    @pkg1 = Package.new(1000, [93,10], :value => 10.00)

    @home_params = {
      :name        => "John Smith", 
      :company     => "test",
      :phone       => "613-555-1212",
      :address1    => "123 Elm St.",
      :city        => 'Ottawa', 
      :province    => 'ON', 
      :country     => 'CA', 
      :postal_code => 'K1P 1J1'
    }
    @home = Location.new(@home_params)

    @dom_params = {
      :name        => "John Smith Sr.", 
      :company     => "",
      :phone       => '123-123-1234',
      :address1    => "5500 Oak Ave",
      :city        => 'Vancouver', 
      :province    => 'BC', 
      :country     => 'CA', 
      :postal_code => 'V5J 2T4'      
    }

    @dest_params = {
      :name     => "Frank White",
      :phone    => '123-123-1234',
      :address1 => '999 Wiltshire Blvd',
      :city     => 'Beverly Hills', 
      :state    => 'CA', 
      :country  => 'US', 
      :zip      => '90210'
    }
    @dest = Location.new(@dest_params)

    @cp = CanadaPostPWS.new(login.merge(:endpoint => "https://ct.soa-gw.canadapost.ca/"))
    @cp.logger = Logger.new(STDOUT)

  end

  def test_rates
    opts = {:customer_number => "0008035576"}
    rates = @cp.find_rates(@home_params, @dom_params, [@pkg1], opts)
    assert_equal RateResponse, rates.class
    assert_equal RateEstimate, rates.rates.first.class
  end

  def test_tracking
    pin = "1371134583769923" # valid pin
    response = @cp.find_tracking_info(pin, {})
    assert_equal 'Xpresspost', response.service_name
    assert response.expected_date.is_a?(Date)
    assert response.customer_number
    assert_equal 10, response.shipment_events.count
  end

  def test_create_shipment
    opts = {:customer_number => "0008035576", :service => "USA.XP"}
    response = @cp.create_shipment(@home_params, @dest_params, [@pkg1], opts)

    p response
  end

end