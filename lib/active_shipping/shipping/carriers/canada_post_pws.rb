require 'cgi'

module ActiveMerchant
  module Shipping
    
    class InvalidPinFormatError < StandardError; end
    class MissingCustomerNumberError < StandardError; end
      
    class CanadaPostPWS < Carrier

      SHIPPING_SERVICES = {
        "DOM.RP"        => "Regular Parcel",
        "DOM.EP"        => "Expedited Parcel",
        "DOM.XP"        => "Xpresspost",
        "DOM.PC"        => "Priority Next A.M.",
        "DOM.LIB"       => "Library Books",
        "USA.EP"        => "Expedited Parcel USA",
        "USA.PW.ENV"    => "Priority Worldwide Envelope USA",
        "USA.PW.PAK"    => "Priority Worldwide pak USA",
        "USA.PW.PARCEL" => "Priority Worldwide Parcel USA",
        "USA.SP.AIR"    => "Small Packet USA Air",
        "USA.SP.SURF"   => "Small Packet USA Surface",
        "USA.XP"        => "Xpresspost USA",
        "INT.IP.AIR"    => "International Parcel Air",
        "INT.IP.SURF"   => "International Parcel Surface",
        "INT.PW.ENV"    => "Priority Worldwide Envelope Int'l",
        "INT.PW.PAK"    => "Priority Worldwide pak Int'l",
        "INT.PW.PARCEL" => "Priority Worldwide parcel Int'l",
        "INT.SP.AIR"    => "Small Packet International Air",
        "INT.SP.SURF"   => "Small Packet International Surface"
      }

      @@name = "Canada Post PWS"
      URL = "https://ct.soa-gw.canadapost.ca/" # test environment
      # URL = "https://soa-gw.canadapost.ca/"    # production
      
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
        
        request_body = build_rates_request(origin, destination, line_items, options)
        p request_body
        response = ssl_post(endpoint, request_body, headers)
        p response
        parse_rates_response(response, origin, destination)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        parse_rates_error_response(e.response.body)
      end
      
      def find_tracking_info(pin, options = {})
        endpoint = case pin.length
          when 12,13,16
            URL + "vis/track/pin/%s/detail" % pin
          when 15
            URL + "vis/track/dnc/%s/detail" % pin
          else
            raise InvalidPinFormatError
          end
        
        headers = {
          'Accept'          => "application/vnd.cpc.track+xml",
          'Authorization'   => encoded_authorization,
          'Accept-language' => language
        }
        # send request & build and parse response
        response = ssl_get(endpoint, headers)
        parse_tracking_response(response)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        parse_tracking_error_response(e.response.body)
      rescue InvalidPinFormatError => e
        CPPWSTrackingResponse.new(false, "Invalid Pin Format", {}, {})
      end
      
      def create_shipment(origin, destination, line_items = [], options = {})
        raise MissingCustomerNumberError unless customer_number = options[:customer_number]

        endpoint = URL + "rs/#{customer_number}/#{customer_number}/shipment"
        headers = {
          'Accept'          => "application/vnd.cpc.shipment+xml",
          'Content-Type'    => "application/vnd.cpc.shipment+xml",
          'Authorization'   => encoded_authorization,
          'Accept-language' => language          
        }

        # build shipment request
        request_body = build_shipment_request(origin, destination, line_items, options)
        
        # get response
        response = ssl_post(endpoint, request_body, headers)
        puts response

        # parse response

      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        puts "Error #{e.response.body}"
      rescue MissingCustomerNumberError => e
        p "Error #{e}"
      end
      
      def void_shipment(label_id, options = {})

      end

      def regenerate_label(label_id, options = {})

      end

      def nearest_offices(origin, options = {})

      end

      def office_details(office_id, options = {})

      end

      
      def maximum_weight
        Mass.new(30, :kilograms)
      end

      private
      
      def encoded_authorization
        "Basic %s" % ActiveSupport::Base64.encode64("#{@options[:api_key]}:#{@options[:secret]}")
      end
      
      def parse_tracking_error_response(response)
        xml = REXML::Document.new(response)
        messages = []
        root_node = xml.elements['messages']
        root_node.elements.each('message') do |message|
          messages << message.get_text('description').to_s
        end
        message = messages.join(",")
        CPPWSTrackingResponse.new(false, message, {}, {})
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
      
      def build_rates_request(origin, destination, line_items = [], options = {})
        origin = Location.new(origin)
        destination = Location.new(destination)
        customer_number  = options[:customer_number]
        contract_number  = options[:contract_number]
        orig_postal_code = origin.postal_code
        shipping_options = options[:shipping_options] || []

        xml = XmlNode.new('mailing-scenario', :xmlns => "http://www.canadapost.ca/ws/ship/rate") do |root_node|
          root_node << XmlNode.new("customer-number", customer_number)
          root_node << XmlNode.new("contract-number", contract_number) if contract_number
          root_node << XmlNode.new("origin-postal-code", orig_postal_code)
          root_node << build_parcel_characteristics(line_items)
          root_node << build_destination_node(destination)
        end
        xml.to_s
      end

      def build_rates_options(options = {}, line_items = [])
        XmlNode.new('options') do |el|
          if options[:cod] && options[:cod_amount]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'COD')
              opt << XmlNode.new('option-amount', options[:cod_amount])
            end
          end

          if options[:insurance] && options[:insurance_amount]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'COV')
              opt << XmlNode.new('option-amount', options[:insurance_amount])
            end
          end

          if options[:signature_required]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'SO')
            end
          end

          [:pa18, :pa19, :hfp, :dns, :lad].each do |code|
            if options[code]
              el << XmlNode.new('option') do |opt|
                opt << XmlNode.new('option-code', code.to_s.upcase)
              end
            end
          end
        end
      end

      def build_parcel_characteristics(line_items = [])
        weight = line_items.sum {|li| li.kilograms }.to_f
        XmlNode.new('parcel-characteristics') do |el|
          el << XmlNode.new('weight', "%#2.3f" % weight)
          el << XmlNode.new('mailing-tube', true) if line_items.any?(&:tube?)
          el << XmlNode.new('oversized', true) if line_items.any?(&:oversized?)
          el << XmlNode.new('unpackaged', true) if line_items.any?(&:unpackaged?)
        end
      end

      def build_destination_node(destination)
        if destination.country_code == 'CA'
          XmlNode.new("destination") do |dest|
            dest << XmlNode.new("domestic") do |dom|
              dom << XmlNode.new('postal-code', destination.postal_code)  
            end
          end
        elsif destination.country_code == 'US'
          XmlNode.new('destination') do |dest|
            dest << XmlNode.new('united-states') do |dom|
              dom << XmlNode.new('zip-code', destination.postal_code)
            end
          end
        else
          XmlNode.new('destination') do |dest|
            dest << XmlNode.new('international') do |dom|
              dom << XmlNode.new('country-code', destination.country_code)
            end
          end
        end
      end


      def build_shipment_request(origin, destination, line_items = [], options = {})
        xml = XmlNode.new('shipment', :xmlns => "http://www.canadapost.ca/ws/shipment") do |root_node|
          # group-id
          root_node << build_groupid_node(options)
          root_node << XmlNode.new('requested-shipping-point', origin.postal_code)
          root_node << XmlNode.new('delivery-spec') do |spec|
            spec << XmlNode.new('service-code', options[:service])
            spec << build_location_node('sender', origin)
            spec << build_location_node('destination', destination)
            spec << build_parcel_characteristics(line_items)
            #spec << build_shipping_options(options)
            #spec << build_notification_options(options)
            spec << build_print_preference_options(options)
            spec << build_shipping_preference_options(options)
            #spec << build_shipping_references(options)
            #spec << build_customs_options(options)
              # skulist
            spec << build_settlement_info(options)        
          end
          # TODO: return-spec
          # TODO: return-recipient

        end
        xml.to_s
      end

      def build_groupid_node(options)
        # need to generate a unique group id (based on date-merchant?)
        XmlNode.new('group-id', 'test')
      end

      def build_shipping_options(options)
        XmlNode.new('options') do |xml|
          # to do
        end
      end

      def build_notification_options(options)
        return unless options[:notification_email]
        XmlNode.new('notification') do |xml|
          xml << XmlNode.new('email', options[:notification_email])
          xml << XmlNode.new('on-shipment', true)
          xml << XmlNode.new('on-shipment', true)
          xml << XmlNode.new('on-shipment', true)
        end
      end

      def build_print_preference_options(options)
        XmlNode.new('print-preferences') do |node|
          node << XmlNode.new('output-format', 'paper')
          node << XmlNode.new('encoding', 'PDF')
        end
      end

      def build_shipping_preference_options(options)
        XmlNode.new('preferences') do |xml|
          xml << XmlNode.new('show-packing-instructions', true)
          xml << XmlNode.new('show-postage-rate', true)
          xml << XmlNode.new('show-insured-value', true)
        end
      end

      def build_shipping_references(options)
        # todo
      end

      def build_customs_options(options)
        # todo
      end


      def build_location_node(label, location)
        XmlNode.new(label) do |xml|
          xml << XmlNode.new('name', location.name)
          if label == 'sender'
            xml << XmlNode.new('company', location.company || location.name)
          else
            xml << XmlNode.new('company', location.company) if location.company
          end
          xml << XmlNode.new('contact-phone', location.phone) if label == 'sender'
          xml << XmlNode.new('address-details') do |addr|
            addr << XmlNode.new('address-line-1', location.address1)
            addr << XmlNode.new('address-line-2', [location.address2, location.address3].join(", ")) if !location.address2.blank? || !location.address3.blank?
            addr << XmlNode.new('city', location.city)
            addr << XmlNode.new('prov-state', location.province)
            addr << XmlNode.new("country-code", location.country_code)
            addr << XmlNode.new('postal-zip-code', location.postal_code)
          end
        end
      end

      def build_settlement_info(options)
        XmlNode.new('settlement-info') do |xml|
          # defaults to mailed-on-behalf-of
          xml << XmlNode.new('contract-id', options[:customer_number])
          xml << XmlNode.new('intended-method-of-payment', 'Account')  # need support for CC
        end
      end

     
      def parse_rates_response(response, origin, destination)
        xml = REXML::Document.new(response)
        root_node = xml.elements['price-quotes']
        
        rates = [] 
        root_node.elements.each('price-quote') do |quote|
          service_name  = quote.get_text("service-name").to_s
          service_code  = quote.get_text("service-code").to_s
          due           = quote.elements['price-details'].get_text("due").to_s
          if service = quote.elements['service-standard']
            expected_date = service.get_text("expected-delivery-date").to_s
          else
            expected_date = nil
          end
          options = {
            :service_code => service_code,
            :total_price => due,
            :currency => 'CAD',
            :delivery_range => [expected_date, expected_date]
          }
          rates << RateEstimate.new(origin, destination, @@name, service_name, options)
        end
        CPPWSRatesResponse.new(true, "", {}, :rates => rates)
      end
      
      def parse_rates_error_response(body)
        xml = REXML::Document.new(body)
        messages = []
        root_node = xml.elements['messages']
        root_node.elements.each('message') do |message|
          messages << message.get_text('description').to_s
        end
        message = messages.join(",")
        CPPWSRatesResponse.new(false, message, {}, {})
      end

      def parse_shipping_response(response)
      end

      def parse_shipping_error_response(body)
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
