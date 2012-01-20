require 'test_helper'
require 'pp'
class CanadaPostPwsTest < Test::Unit::TestCase

  def setup
    login = fixtures(:canada_post_pws)
    
    # 100 grams, 93 cm long, 10 cm diameter, cylinders have different volume calculations
    @pkg1 = Package.new(25, [93,10], :cylinder => true)
    # 7.5 lbs, times 16 oz/lb., 15x10x4.5 inches, not grams, not centimetres
    @pkg2 = Package.new(  (7.5 * 16), [15, 10, 4.5], :units => :imperial)
    
    @home = Location.new(:country => 'CA', :province => 'ON', :city => 'Ottawa', :postal_code => 'K1P1J1')
    @dest = Location.new(:country => 'US', :state => 'CA', :city => 'Beverly Hills', :zip => '90210')

    @cp = CanadaPostPWS.new(login)
    @french_cp = CanadaPostPWS.new(login.merge(:language => 'fr'))
  end
  
  # def test_real  # actually hit Canada Post API
  #   pin = "1371134583769924" # valid test #
  #   
  #   response = @cp.find_tracking_info(pin, {})
  #   p response
  # end

  # def test_rates # HITS endpoint
    # opts = {:customer_number => "0008035576"}
    # ca_dest = Location.new(:country => 'CA', :province => 'BC', :city => "Vancouver", :postal_code => "V5J2T2")
    # response =  @cp.find_rates(@home, ca_dest, [@pkg1], opts)
    # p response
    # response.rates.each do |rate| 
    #   p rate.package_rates
    # end
  # end
  

  # find_tracking_info

  def test_find_tracking_info_with_valid_pin
    pin = '1371134583769923'
    endpoint = CanadaPostPWS::URL + "vis/track/pin/%s/detail" % pin
    @response = xml_fixture('canadapost_pws/tracking_details_en')
    @cp.expects(:ssl_get).with(endpoint, anything).returns(@response)
  
    response = @cp.find_tracking_info(pin)
    assert response.is_a?(CPPWSTrackingResponse)  
  end
  
  def test_find_tracking_info_with_15_digit_dnc
    dnc = "315052413796541"
    endpoint = CanadaPostPWS::URL + "vis/track/dnc/%s/detail" % dnc
    @response = xml_fixture('canadapost_pws/dnc_tracking_details_en')
    @cp.expects(:ssl_get).with(endpoint, anything).returns(@response)
  
    response = @cp.find_tracking_info(dnc)
    assert response.is_a?(CPPWSTrackingResponse)
  end
  
  def test_find_tracking_info_when_pin_doesnt_exist
    pin = '1371134583769924'
    body = xml_fixture('canadapost_pws/tracking_details_en_error')
    
    CPPWSTrackingResponse.any_instance.stubs(:body).returns(body)
    @cp.expects(:ssl_get).raises(ActiveMerchant::Shipping::ResponseError)
    ActiveMerchant::Shipping::ResponseError.any_instance.expects(:response).returns(mock(:body => body))
    @cp.expects(:parse_tracking_error_response).raises(ActiveMerchant::Shipping::ResponseError)
    
    exception = assert_raises ActiveMerchant::Shipping::ResponseError do
      @cp.find_tracking_info(pin)
    end
  end
  
  def test_find_tracking_info_with_invalid_pin_format
    pin = '123'
    @cp.expects(:ssl_get).never
    
    exception = assert_raises ActiveMerchant::Shipping::ResponseError do
      @cp.find_tracking_info(pin)
    end
    assert_equal "Invalid Pin Format", exception.message
  end
  
  # parse_tracking_response
  
  def test_parse_tracking_response
    @response = xml_fixture('canadapost_pws/tracking_details_en')
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
    @response = xml_fixture('canadapost_pws/tracking_details_en')
    @cp.expects(:ssl_get).returns(@response)
    
    response = @cp.find_tracking_info('1371134583769923', {})
    events = response.shipment_events
    
    event = events.first
    assert_equal ShipmentEvent, event.class
    assert_equal "1496", event.name
    assert_equal "SAINTE-FOY, QC", event.location
    assert event.time.is_a?(Time)
    assert_equal "Item successfully delivered", event.message

    timestamps = events.map(&:time)
    ordered = timestamps.dup.sort.reverse # newest => oldest
    assert_equal ordered, timestamps
  end

  # parse_error_response

  def test_parse_tracking_error_response
    body = xml_fixture('canadapost_pws/tracking_details_en_error')
    exception = assert_raises ActiveMerchant::Shipping::ResponseError do
      @cp.send(:parse_tracking_error_response, body)
    end
    assert_equal "No Pin History", exception.message
  end


  # rating
  
  # build_rates_options

  def test_build_rates_options_no_options
    options = {}
    response = @cp.send(:build_rates_options, options, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//options')
    assert_equal 1, values.size
    assert_equal 0, doc.xpath('//options/option').size
  end
  
  def test_build_rates_options_with_signature
    options = {:signature_required => true}
    response = @cp.send(:build_rates_options, options, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//options/option')
    assert_equal 1, values.size
    assert_equal "SO", values.first.content
  end
  
  def test_build_rates_options_with_coverage
    options = {:insurance => true, :insurance_amount => 100.00 }
    response = @cp.send(:build_rates_options, options, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    assert_equal 1, doc.xpath('//options/option').size
    code = doc.xpath('//options/option/option-code')
    amt = doc.xpath('//options/option/option-amount')
    assert_equal "COV", code.first.content
    assert_equal "100.0", amt.first.content
  end
  
  def test_build_rates_options_with_cod
    options = {:cod => true, :cod_amount => 100.00 }
    response = @cp.send(:build_rates_options, options, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    assert_equal 1, doc.xpath('//options/option').size
    code = doc.xpath('//options/option/option-code')
    amt = doc.xpath('//options/option/option-amount')
    assert_equal "COD", code.first.content
    assert_equal "100.0", amt.first.content    
  end
  
  def test_build_rates_options_with_other_options
    options = {:pa18 => true, :pa19 => true, :dns => true, :lad => true, :hfp => true}
    response = @cp.send(:build_rates_options, options, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    assert_equal 5, doc.xpath('//options/option').size
    codes = doc.xpath('//options/option/option-code').map {|code| code.content }
    assert_equal ["PA18", "PA19", "HFP", "DNS", "LAD"], codes
  end
  

  # build_parcel_characteristics

  def test_build_parcel_characteristics_with_single_item
    response = @cp.send(:build_parcel_characteristics, [@pkg1])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//parcel-characteristics/weight')
    assert_equal 1, values.size
    assert_equal "0.025", values.first.content
  end
  
  def test_build_parcel_characteristics_with_multiple_items
    response = @cp.send(:build_parcel_characteristics, [@pkg1, @pkg2])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//parcel-characteristics/weight')
    assert_equal 1, values.size
    assert_equal "3.427", values.first.content
  end

  def test_build_parcel_characteristics_with_mailing_tube
    pkg = Package.new(25, [93,10], :cylinder => true)
    response = @cp.send(:build_parcel_characteristics, [pkg])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//parcel-characteristics/mailing-tube')
    assert_equal 1, values.size
    assert_equal "true", values.first.content
  end
  
  def test_build_parcel_characteristics_with_oversided_item
    pkg = Package.new(25, [93,10], :oversized => true)
    response = @cp.send(:build_parcel_characteristics, [pkg])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//parcel-characteristics/oversized')
    assert_equal 1, values.size
    assert_equal "true", values.first.content
  end
  
  def test_build_parcel_characteristics_with_unpackaged_item
    pkg = Package.new(25, [93,10], :unpackaged => true)
    response = @cp.send(:build_parcel_characteristics, [pkg])
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//parcel-characteristics/unpackaged')
    assert_equal 1, values.size
    assert_equal "true", values.first.content
  end


  # build_destination_node

  def test_build_destination_node_with_domestic_address
    response = @cp.send(:build_destination_node, @home)
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//destination/domestic/postal-code')
    assert_equal 1, values.size
    assert_equal "K1P1J1", values.first.content
    
  end
  
  def test_build_destination_node_with_us_address
    response = @cp.send(:build_destination_node, @dest)
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//destination/united-states/zip-code')
    assert_equal 1, values.size
    assert_equal "90210", values.first.content
  end
  
  def test_build_destination_node_with_international_address
    location = Location.new(:country => "Japan", :city => "Tokyo")
    response = @cp.send(:build_destination_node, location)
    doc = Nokogiri::XML(response.to_s)
    values = doc.xpath('//destination/international/country-code')
    assert_equal 1, values.size
    assert_equal "JP", values.first.content
  end


  def test_parse_rates_response
    @response = xml_fixture('canadapost_pws/rates_info')
    @cp.expects(:ssl_post).returns(@response)

    response = @cp.find_rates(@home, @dest, [], {})

    assert_equal CPPWSRatesResponse, response.class
    rate = response.rates.first
    assert_equal 1301, rate.total_price
    assert_equal "DOM.EP", rate.service_code
    assert_equal "Expedited Parcel", rate.service_name
    assert_equal rate.delivery_range, [DateTime.parse("18 Jan 2012"),DateTime.parse("18 Jan 2012")]
  end

  def test_parse_error_rates_response
    body = xml_fixture('canadapost_pws/rates_info_error')
    exception = assert_raises ActiveMerchant::Shipping::ResponseError do
      @cp.send(:parse_rates_error_response, body)
    end

    assert_equal "You cannot mail on behalf of the requested customer.", exception.message
  end

  def test_find_rates_returns_error
    body = xml_fixture('canadapost_pws/rates_info_error')
    
    CPPWSRatesResponse.any_instance.stubs(:body).returns(body)
    @cp.expects(:ssl_post).raises(ActiveMerchant::Shipping::ResponseError)
    ActiveMerchant::Shipping::ResponseError.any_instance.expects(:response).returns(mock(:body => body))
    @cp.expects(:parse_rates_error_response).raises(ActiveMerchant::Shipping::ResponseError)
    
    assert_raises ActiveMerchant::Shipping::ResponseError do
      @cp.find_rates(@home, @dest, [], {})
    end
  end

  
  
  # label printing
  

end
