require 'test_helper'
require 'pp'
class CanadaPostPwsRatingTest < Test::Unit::TestCase

  def setup
    login = fixtures(:canada_post_pws)
    
    # 100 grams, 93 cm long, 10 cm diameter, cylinders have different volume calculations
    @pkg1 = Package.new(25, [93,10], :cylinder => true)
    # 7.5 lbs, times 16 oz/lb., 15x10x4.5 inches, not grams, not centimetres
    @pkg2 = Package.new((7.5 * 16), [15, 10, 4.5], :units => :imperial)
    
    @home = Location.new({
      :name        => "John Smith", 
      :company     => "test",
      :phone       => "613-555-1212",
      :address1    => "123 Elm St.",
      :city        => 'Ottawa', 
      :province    => 'ON', 
      :country     => 'CA', 
      :postal_code => 'K1P1J1'
    })

    @dest = Location.new({
      :name     => "Frank White",
      :address1 => '999 Wiltshire Blvd',
      :city     => 'Beverly Hills', 
      :state    => 'CA', 
      :country  => 'US', 
      :zip      => '90210'
    })

    @cp = CanadaPostPWS.new(login)
    @french_cp = CanadaPostPWS.new(login.merge(:language => 'fr'))
  end
  
  # def test_rates # HITS endpoint
    # opts = {:customer_number => "0008035576"}
    # ca_dest = Location.new(:country => 'CA', :province => 'BC', :city => "Vancouver", :postal_code => "V5J2T2")
    # response =  @cp.find_rates(@home, ca_dest, [@pkg1], opts)
    # p response
    # response.rates.each do |rate| 
    #   p rate.package_rates
    # end
  # end


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
end
