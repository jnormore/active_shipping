require 'test_helper'
require 'pp'
class CanadaPostPwsTest < Test::Unit::TestCase

  def setup
    login = fixtures(:canada_post_pws)
    
    # 100 grams, 93 cm long, 10 cm diameter, cylinders have different volume calculations
    @pkg1 = Package.new(1, [93,10], :cylinder => true)
    # 7.5 lbs, times 16 oz/lb., 15x10x4.5 inches, not grams, not centimetres
    @pkg2 = Package.new(  (7.5 * 16), [15, 10, 4.5], :units => :imperial)
    
    @home = Location.new(:country => 'CA', :province => 'ON', :city => 'Ottawa', :postal_code => 'K1P1J1')
    @dest = Location.new(:country => 'US', :state => 'CA', :city => 'Beverly Hills', :zip => '90210')
    
    @cp = CanadaPostPWS.new(login)
    @french_cp = CanadaPostPWS.new(login.merge(:language => 'fr'))
  end

  # tracking info
  
  def test_real  # actually hit Canada Post API
    pin = "1371134583769924" # valid test #
    
    response = @cp.find_tracking_info(pin, {})
    p response
  end
  
  
  
  def test_find_tracking_info_with_valid_pin
    pin = '1371134583769923'
    endpoint = CanadaPostPWS::URL + "vis/track/pin/%s/detail" % pin
    @response = xml_fixture('canadapost_pws/tracking_details_en')
    @cp.expects(:ssl_get).with(endpoint, anything).returns(@response)
  
    response = @cp.find_tracking_info(pin, {})
    assert response.is_a?(CPPWSTrackingResponse)  
  end
  
  def test_find_tracking_info_with_15_digit_dnc
    dnc = "315052413796541"
    endpoint = CanadaPostPWS::URL + "vis/track/dnc/%s/detail" % dnc
    @response = xml_fixture('canadapost_pws/dnc_tracking_details_en')
    @cp.expects(:ssl_get).with(endpoint, anything).returns(@response)
  
    response = @cp.find_tracking_info(dnc, {})
    assert response.is_a?(CPPWSTrackingResponse)
  end
  
  def test_find_tracking_info_with_invalid_format_pin_returns_error
    pin = '123'
    @cp.expects(:ssl_get).never
    assert_raises ResponseError do
      response = @cp.find_tracking_info(pin, {})
    end
  end

  # when number is pin, but pin does not exist, returns back message (returns 404, body should contain error info)
  # when number is valid dnc format, but dnc does not exist, returns back message
  # when number is invalid, returns back error
  # no support for search
  
  
  # 
  # def test_find_tracking_info_in_french
  #   packages = [@pkg1, @pkg2]
  #   response = @cp.find_tracking_info('1371134583769923', {})
  #   assert response.is_a?(CPPWSTrackingResponse)
  # end
  # 
  # def test_find_tracking_info_with_invalid_pin_should_raise_response_error # ?
  # end
  # 
  # def test_find_tracking_info_with_server_error_raises_response_error
  # end
  # 
  
  # parse_tracking_info
  # test events
  # test expected-delivery-date
  # test service-name
  # test changed date, and change reason
  # test event name, date, time, location
  # test event timestamp

  def test_parse_tracking_response
    @response = xml_fixture('canadapost_pws/tracking_info')
    @cp.expects(:ssl_get).returns(@response)
    
    response = @cp.find_tracking_info('1371134583769923', {})
    
    assert_equal CPPWSTrackingResponse, response.class
    assert_equal "Xpresspost", response.service_name
    assert_equal Date.parse("2011-02-01"), response.expected_date
    assert_equal "Customer addressing error found; attempting to correct", response.change_reason
    assert_equal "1371134583769923", response.tracking_number
    assert_equal 10, response.shipment_events.size
    assert response.origin.is_a?(Location)
    assert_equal "", response.origin.to_s
    assert response.destination.is_a?(Location)
    assert_equal "G1K4M7", response.destination.to_s
    assert_equal "0001371134", response.customer_number
  end

  def test_parse_tracking_response_shipment_events
    @response = xml_fixture('canadapost_pws/tracking_info')
    @cp.expects(:ssl_get).returns(@response)
    
    response = @cp.find_tracking_info('1371134583769923', {})
    events = response.shipment_events
    
    event = events.first
    assert_equal ShipmentEvent, event.class
    assert_equal "1496", event.name
    assert_equal "SAINTE-FOY, QC", event.location
    assert event.time.is_a?(Time), event.time.class
    assert_equal "Item successfully delivered", event.message

    timestamps = events.map(&:time)
    ordered = timestamps.dup.sort.reverse # newest => oldest
    assert_equal ordered, timestamps
  end

  def test_parse_rates_response
    @response = xml_fixture('canadapost_pws/rates_info')
    @cp.expects(:ssl_post).returns(@response)

    response = @cp.find_rates(@home, @dest, [], {})

    assert_equal CPPWSRatesResponse, response.class
    rate = response.rates.first
    assert_equal 1021, rate.total_price
    assert_equal "DOM.EP", rate.service_code
    assert_equal "Expedited Parcel", rate.service_name
    assert_equal rate.delivery_range, [DateTime.parse("24 October 2011"),DateTime.parse("24 October 2011")]
  end


  # rating

  def test_rates
    opts = {:customer_number => "0008035576"}
    ca_dest = Location.new(:country => 'CA', :province => 'MB', :city => "Winnipeg", :postal_code => "R3L0K9")
    @cp.find_rates(@home, ca_dest, [@pkg1], opts)
  end
  

  
  
  # label printing
  

end
