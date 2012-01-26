require 'test_helper'
require 'pp'
class CanadaPostPwsTest < Test::Unit::TestCase

  def setup
    login = fixtures(:canada_post_pws)
    
    # 100 grams, 93 cm long, 10 cm diameter, cylinders have different volume calculations
    @pkg1 = Package.new(25, [93,10], :cylinder => true)
    # 7.5 lbs, times 16 oz/lb., 15x10x4.5 inches, not grams, not centimetres
    @pkg2 = Package.new(  (7.5 * 16), [15, 10, 4.5], :units => :imperial)
    
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


  def test_shipment
    opts = {:customer_number => "0008035576", :service => "DOM.EP"}
    ca_dest = Location.new({
      :name        => "Jane White",
      :phone       => '604-555-1212',
      :address1    => '5555 Trafalgar St.',
      :city        => "Vancouver",
      :province    => 'BC',
      :country     => 'CA', 
      :postal_code => "V5J2T2"
    })
    response = @cp.create_shipment(@home, ca_dest, [@pkg1], opts)
    
    puts response
  end

    
  
end



# <?xml version="1.0"?>
# <shipment xmlns="http://www.canadapost.ca/ws/shipment">
#   <group-id>test</group-id>
#   <requested-shipping-point>K1P1J1</requested-shipping-point>
#   <delivery-spec>
#     <service-code>DOM.EP</service-code>
#     <sender>
#       <name>John Smith</name>
#       <company>test</company>
#       <contact-phone>613-555-1212</contact-phone>
#       <address-details>
#         <address-line-1>123 Elm St.</address-line-1>
#         <city>Ottawa</city>
#         <prov-state>ON</prov-state>
#         <country-code>CA</country-code>
#         <postal-zip-code>K1P1J1</postal-zip-code>
#       </address-details>
#     </sender>
#     <destination>
#       <name>Jane White</name>
#       <address-details>
#         <address-line-1>5555 Trafalgar St.</address-line-1>
#         <city>Vancouver</city>
#         <prov-state>BC</prov-state>
#         <country-code>CA</country-code>
#         <postal-zip-code>V5J2T2</postal-zip-code>
#       </address-details>
#     </destination>
#     <parcel-characteristics>
#       <weight>0.025</weight>
#       <mailing-tube>true</mailing-tube>
#     </parcel-characteristics>
#     <print-preferences>
#       <output-format>paper</output-format>
#       <encoding>PDF</encoding>
#     </print-preferences>
#     <preferences>
#       <show-packing-instructions>true</show-packing-instructions>
#       <show-postage-rate>true</show-postage-rate>
#       <show-insured-value>true</show-insured-value>
#     </preferences>
#     <settlement-info>
#       <contract-id>0008035576</contract-id>
#       <intended-method-of-payment>Account</intended-method-of-payment>
#     </settlement-info>
#   </delivery-spec>
# </shipment>

# <?xml version="1.0" encoding="UTF-8"?>
# <shipment-info xmlns="http://www.canadapost.ca/ws/shipment">
#   <shipment-id>340531309186521749</shipment-id>
#   <shipment-status>created</shipment-status>
#   <tracking-pin>7023210883561103</tracking-pin>
#   <links>
#     <link rel="self" href="https://ct.soa-gw.canadapost.ca/rs/0008035576/0008035576/shipment/340531309186521749" media-type="application/vnd.cpc.shipment+xml"/>
#     <link rel="details" href="https://ct.soa-gw.canadapost.ca/rs/0008035576/0008035576/shipment/340531309186521749/details" media-type="application/vnd.cpc.shipment+xml"/>
#     <link rel="group" href="https://ct.soa-gw.canadapost.ca/rs/0008035576/0008035576/shipment?groupId=123456" media-type="application/vnd.cpc.shipment+xml"/>
#     <link rel="price" href="https://ct.soa-gw.canadapost.ca/rs/0008035576/0008035576/shipment/340531309186521749/price" media-type="application/vnd.cpc.shipment+xml"/>
#     <link rel="label" href="https://ct.soa-gw.canadapost.ca/ers/artifact/c70da5ed5a0d2c32/10238/0" media-type="application/pdf" index="0"/>
#   </links>
# </shipment-info>
