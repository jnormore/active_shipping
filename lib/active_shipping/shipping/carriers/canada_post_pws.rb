require 'cgi'

module ActiveMerchant
  module Shipping
    
    class CanadaPostPWS < Carrier

      @@name = "Canada Post PWS"
      # URL = "https://ct.soa-gw.canadapost.ca/" # test environment
      URL = "https://soa-gw.canadapost.ca/"    # production
      
      Language = {
        'en' => 'en-CA',
        'fr' => 'fr-CA'
      }
      
      attr_accessor :language
      
      def initialize(options = {})
        @language = Language[options[:language]] || Language['en']
        super(options)
      end
      
      def requirements
        [:api_key, :secret]
      end
      
      def find_rates(origin, destination, line_items = [], options = {})
        endpoint = URL + "rs/ship/price"      
        
        headers = {
          'Accept'          => 'application/vnd.cpc.ship.rate+xml',
          'Content-Type'    => 'application/vnd.cpc.ship.rate+xml',
          'Authorization'   => encoded_authorization,
          'Accept-Language' => language
        }
        xml = XmlNode.new('mailing-scenario', :xmlns => "http://www.canadapost.ca/ws/ship/rate") do |root_node|
          root_node << XmlNode.new("customer-number", options[:customer_number])
          root_node << XmlNode.new("parcel-characteristics") do |pc|
            weight = line_items.reduce(0){|acc, li| acc + li.weight}
            pc << XmlNode.new("weight", weight)
          end
          root_node << XmlNode.new("origin-postal-code", origin.postal_code)
          root_node << XmlNode.new("destination") do |dest|
            dest << XmlNode.new("domestic") do |dom|
              dom << XmlNode.new("postal-code", destination.postal_code)
            end
          end
        end
        
        data = xml.to_s
        
        response = ssl_post(endpoint, data, headers)
        
        parse_rates_response(response, origin, destination)
      end
      
      # def tracking_summary(pin, options ={})
      #   endpoint = URL + "vis/track/pin/%s/summary" % pin
      #   headers = {
      #     'Accept'          => "application/vnd.cpc.track+xml",
      #     'Authorization'   => encoded_authorization,
      #     'Accept-language' => language
      #   }
      #   response = ssl_get(endpoint, headers)
      #   p response
      # end
      
      def find_tracking_info(pin, options = {})
        endpoint = case pin.length
          when 12,13,16
            URL + "vis/track/pin/%s/detail" % pin
          when 15
            URL + "vis/track/dnc/%s/detail" % pin
          else
            CPPWSTrackingResponse.new(false, "Invalid PIN format", {}, {})
          end
        
        # set required header
        headers = {
          'Accept'          => "application/vnd.cpc.track+xml",
          'Authorization'   => encoded_authorization,
          'Accept-language' => language
        }
        # send request & build and parse response
        response = ssl_get(endpoint, headers)
        parse_tracking_response(response)
      rescue ActiveMerchant::ResponseError => e
        puts e.response.body
        puts e.message
      end
      
      def print_label(origin, destination, options = {})
      end
      
      def void_label(label_id, options = {})
      end
      
      def maximum_weight
        Mass.new(30, :kilograms)
      end

      private
      
      def encoded_authorization
        "Basic %s" % ActiveSupport::Base64.encode64("#{@options[:api_key]}:#{@options[:secret]}")
      end
      
      def parse_invalid_tracking_response(response, message)
        CPPWSTrackingResponse.new(false, message, {}, {})
      end
      
      
      def parse_rates_response(response, origin, destination)
        xml = REXML::Document.new(response)
        
        rates = [] 
        
        root_node = xml.elements['price-quotes']
        
        root_node.elements.each('price-quote') do |quote|
          service_name  = quote.get_text("service-name").to_s
          service_code  = quote.get_text("service-code").to_s
          due           = quote.elements['price-details'].get_text("due").to_s
          expected_date = quote.elements['service-standard'].get_text("expected-delivery-date").to_s
          
          rates << RateEstimate.new(origin, destination, @@name, service_name,
            :service_code => service_code,
            :total_price => due,
            :currency => 'CAD',
            :delivery_range => [expected_date, expected_date]
            )
        end
        CPPWSRatesResponse.new(true, "", {}, :rates => rates)
      end
      
      def parse_tracking_response(response)
        xml = REXML::Document.new(response)
        #puts response
        root_node = xml.elements['tracking-detail']

        # build shipment events
        shipment_events = []
        events = root_node.elements['significant-events']
        events.elements.each('occurrence') do |event|
          date      = event.get_text('event-date').to_s
          time      = event.get_text('event-time').to_s
          zone      = event.get_text('event-time-zone').to_s
          timestamp = DateTime.parse("#{date} #{time} #{zone}")
          time      = Time.utc(timestamp.utc.year, timestamp.utc.month, timestamp.utc.day, timestamp.utc.hour, timestamp.utc.min, timestamp.utc.sec)
          message   = event.get_text('event-description').to_s
          location  = [event.get_text('event-retail-name'), event.get_text('event-site'), event.get_text('event-province')].compact.join(", ")
          name      = event.get_text('event-identifier').to_s
          
          shipment_events << ShipmentEvent.new(name, time, location, message)
        end
        
        change_date      = root_node.get_text('changed-expected-date').to_s
        expected_date    = root_node.get_text('expected-delivery-date').to_s
        dest_postal_code = root_node.get_text('destination-postal-id').to_s
        destination      = Location.new(:postal_code => dest_postal_code)
        origin           = Location.new({})        
        options = {
          :service_name            => root_node.get_text('service-name').to_s,
          :expected_date           => Date.parse(expected_date),
          :changed_date            => change_date.blank? ? nil : Date.parse(change_date),
          :change_reason           => root_node.get_text('changed-expected-delivery-reason').to_s.strip,
          :destination_postal_code => root_node.get_text('destination-postal-id').to_s,
          :shipment_events         => shipment_events,
          :tracking_number         => root_node.get_text('pin').to_s,
          :origin                  => origin,
          :destination             => destination,
          :customer_number         => root_node.get_text('mailed-by-customer-number').to_s
        }
        
        CPPWSTrackingResponse.new(true, "", {}, options)
      end
      
    end
    
    class CPPWSRatesResponse < RateResponse
    end
    
    class CPPWSTrackingResponse < TrackingResponse
      
      attr_reader :service_name
      attr_reader :expected_date
      attr_reader :changed_date
      attr_reader :change_reason
      attr_reader :customer_number
      
      def initialize(success, message, params = {}, options = {})
        super
        @service_name    = options[:service_name]
        @expected_date   = options[:expected_date]
        @changed_date    = options[:changed_date]
        @change_reason   = options[:change_reason]
        @customer_number = options[:customer_number]
      end
      
    end
    
  end
end

# sample tracking response
# <?xml version="1.0" encoding="UTF-8"?>
# <tracking-detail xmlns="http://www.canadapost.ca/ws/track">
#   <pin>1371134583769923</pin>
#   <active-exists>1</active-exists>
#   <archive-exists/>
#   <changed-expected-date>2011-02-11</changed-expected-date>
#   <destination-postal-id>G1K4M7</destination-postal-id>
#   <expected-delivery-date>2011-02-01</expected-delivery-date>
#   <changed-expected-delivery-reason>Customer addressing error found; attempting to correct
#       </changed-expected-delivery-reason>
#   <mailed-by-customer-number>0001371134</mailed-by-customer-number>
#   <mailed-on-behalf-of-customer-number>0001371134</mailed-on-behalf-of-customer-number>
#   <original-pin/>
#   <service-name>Xpresspost</service-name>
#   <service-name-2>Xpresspost</service-name-2>
#   <customer-ref-1>955-0398</customer-ref-1>
#   <customer-ref-2/>
#   <return-pin/>
#   <signature-image-exists>true</signature-image-exists>
#   <suppress-signature>false</suppress-signature>
#   <delivery-options>
#     <item>
#       <delivery-option/>
#       <delivery-option-description/>
#     </item>
#     <item>
#       <delivery-option>CH_SGN_OPTION</delivery-option>
#       <delivery-option-description>Signature Required</delivery-option-description>
#     </item>
#   </delivery-options>
#   <significant-events>
#     <occurrence>
#       <event-identifier>1496</event-identifier>
#       <event-date>2011-02-03</event-date>
#       <event-time>11:59:59</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Item successfully delivered</event-description>
#       <signatory-name/>
#       <event-site>SAINTE-FOY</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>20</event-identifier>
#       <event-date>2011-02-03</event-date>
#       <event-time>11:59:59</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Signature image recorded for Online viewing</event-description>
#       <signatory-name>HETU</signatory-name>
#       <event-site>SAINTE-FOY</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>0174</event-identifier>
#       <event-date>2011-02-03</event-date>
#       <event-time>08:27:43</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Item out for delivery</event-description>
#       <signatory-name/>
#       <event-site>SAINTE-FOY</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>0100</event-identifier>
#       <event-date>2011-02-02</event-date>
#       <event-time>14:45:48</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Item processed at postal facility</event-description>
#       <signatory-name/>
#       <event-site>QUEBEC</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>0173</event-identifier>
#       <event-date>2011-02-02</event-date>
#       <event-time>06:19:57</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Customer addressing error found; attempting to correct.
#             Possible delay</event-description>
#       <signatory-name/>
#       <event-site>QUEBEC</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>1496</event-identifier>
#       <event-date>2011-02-01</event-date>
#       <event-time>07:59:52</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Item successfully delivered</event-description>
#       <signatory-name/>
#       <event-site>QUEBEC</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>20</event-identifier>
#       <event-date>2011-02-01</event-date>
#       <event-time>07:59:52</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Signature image recorded for Online viewing</event-description>
#       <signatory-name>R GREGOIRE</signatory-name>
#       <event-site>QUEBEC</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>0500</event-identifier>
#       <event-date>2011-02-01</event-date>
#       <event-time>07:51:23</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Out for delivery</event-description>
#       <signatory-name/>
#       <event-site>QUEBEC</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>2300</event-identifier>
#       <event-date>2011-01-31</event-date>
#       <event-time>17:06:02</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Item picked up by Canada Post</event-description>
#       <signatory-name/>
#       <event-site>MONTREAL</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#     <occurrence>
#       <event-identifier>3000</event-identifier>
#       <event-date>2011-01-31</event-date>
#       <event-time>14:34:57</event-time>
#       <event-time-zone>EST</event-time-zone>
#       <event-description>Order information received by Canada Post</event-description>
#       <signatory-name/>
#       <event-site>LACHINE</event-site>
#       <event-province>QC</event-province>
#       <event-retail-location-id/>
#       <event-retail-name/>
#     </occurrence>
#   </significant-events>
# </tracking-detail>

