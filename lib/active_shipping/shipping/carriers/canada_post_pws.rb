require 'cgi'

module ActiveMerchant
  module Shipping
          
    class CanadaPostPWS < Carrier
      @@name = "Canada Post PWS"

      SHIPPING_SERVICES = {
        "DOM.RP"        => "Regular Parcel",
        "DOM.EP"        => "Expedited Parcel",
        "DOM.XP"        => "Xpresspost",
        "DOM.XP.CERT"   => "Xpresspost Certified",
        "DOM.PC"        => "Priority",
        "DOM.LIB"       => "Library Books",

        "USA.EP"        => "Expedited Parcel USA",
        "USA.PW.ENV"    => "Priority Worldwide Envelope USA",
        "USA.PW.PAK"    => "Priority Worldwide pak USA",
        "USA.PW.PARCEL" => "Priority Worldwide Parcel USA",
        "USA.SP.AIR"    => "Small Packet USA Air",
        "USA.SP.SURF"   => "Small Packet USA Surface",
        "USA.XP"        => "Xpresspost USA",

        "INT.XP"        => "Xpresspost International",
        "INT.IP.AIR"    => "International Parcel Air",
        "INT.IP.SURF"   => "International Parcel Surface",
        "INT.PW.ENV"    => "Priority Worldwide Envelope Int'l",
        "INT.PW.PAK"    => "Priority Worldwide pak Int'l",
        "INT.PW.PARCEL" => "Priority Worldwide parcel Int'l",
        "INT.SP.AIR"    => "Small Packet International Air",
        "INT.SP.SURF"   => "Small Packet International Surface"
      }

      ENDPOINT = "https://soa-gw.canadapost.ca/"    # production
      
      LANGUAGE = {
        'en' => 'en-CA',
        'fr' => 'fr-CA'
      }
      
      attr_accessor :language, :endpoint, :logger

      def initialize(options = {})
        @language = LANGUAGE[options[:language]] || LANGUAGE['en']
        @endpoint = options[:endpoint] || ENDPOINT
        super(options)
      end
      
      def requirements
        [:api_key, :secret]
      end
      
      def find_rates(origin, destination, line_items = [], options = {})
        url = endpoint + "rs/ship/price"              
        headers  = {
          'Accept'          => 'application/vnd.cpc.ship.rate+xml',
          'Content-Type'    => 'application/vnd.cpc.ship.rate+xml',
          'Authorization'   => encoded_authorization,
          'Accept-Language' => language
        }
        
        request  = build_rates_request(origin, destination, line_items, options)
        response = ssl_post(url, request, headers)
        parse_rates_response(response, origin, destination)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        error_response(response, RateResponse)
      end
      
      def find_tracking_info(pin, options = {})
        url = case pin.length
          when 12,13,16
            endpoint + "vis/track/pin/%s/detail" % pin
          when 15
            endpoint + "vis/track/dnc/%s/detail" % pin
          else
            raise InvalidPinFormatError
          end
        
        headers = {
          'Accept'          => "application/vnd.cpc.track+xml",
          'Authorization'   => encoded_authorization,
          'Accept-language' => language
        }

        response = ssl_get(url, headers)
        parse_tracking_response(response)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        error_response(response, CPPWSTrackingResponse)
      rescue InvalidPinFormatError => e
        CPPWSTrackingResponse.new(false, "Invalid Pin Format", {}, {})
      end
      
      def create_label(origin, destination, line_items = [], options = {})
        raise MissingCustomerNumberError unless customer_number = options[:customer_number]

        url = endpoint + "rs/#{customer_number}/#{customer_number}/shipment"
        headers = {
          'Accept'          => "application/vnd.cpc.shipment+xml",
          'Content-Type'    => "application/vnd.cpc.shipment+xml",
          'Authorization'   => encoded_authorization,
          'Accept-language' => language          
        }

        # build shipment request
        request_body = build_shipment_request(origin, destination, line_items, options)
        
        # get response
        response = ssl_post(url, request_body, headers)
        puts response
        # TODO parse response
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        puts "Error #{e.response.body}"
      rescue MissingCustomerNumberError => e
        p "Error #{e}"
      end
      
      def cancel_label(label_id, options = {})
        # future
      end

      def regenerate_label(label_id, options = {})
        # future
      end

      
      def maximum_weight
        Mass.new(30, :kilograms)
      end


      # rating

      def build_rates_request(origin, destination, line_items = [], options = {})
        #log("origin: #{origin.inspect} dest: #{destination.inspect} items: #{line_items.inspect} opts: #{options.inspect}")
        xml =  XmlNode.new('mailing-scenario', :xmlns => "http://www.canadapost.ca/ws/ship/rate") do |node|
          node << customer_number_node(options)
          node << contract_id_node(options)
          node << quote_type_node(options)
          node << shipping_options_node(options)
          node << parcel_node(line_items)
          node << origin_node(origin)
          node << destination_node(destination)
        end
        xml.to_s
      end

      def parse_rates_response(response, origin, destination)
        doc = REXML::Document.new(response)
        raise ActiveMerchant::Shipping::ResponseError, "No Quotes" unless doc.elements['price-quotes']

        quotes = doc.elements['price-quotes'].elements.collect('price-quote') {|node| node }
        rates = quotes.map do |node|
          service_name  = node.get_text("service-name").to_s
          service_code  = node.get_text("service-code").to_s
          total_price   = node.elements['price-details'].get_text("due").to_s
          expected_date = expected_date_from_node(node)
          options = {
            :service_code   => service_code,
            :total_price    => total_price,
            :currency       => 'CAD',
            :delivery_range => [expected_date, expected_date]
          }
          RateEstimate.new(origin, destination, @@name, service_name, options)
        end
        RateResponse.new(true, "", {}, :rates => rates)
      end


      # tracking
      
      def parse_tracking_response(response)
        doc = REXML::Document.new(response)
        raise ActiveMerchant::Shipping::ResponseError, "No Tracking" unless root_node = doc.elements['tracking-detail']

        events = root_node.elements['significant-events'].elements.collect('occurrence') {|node| node }

        shipment_events  = build_shipment_events(events)
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

      def build_shipment_events(events)
        events.map do |event|
          date      = event.get_text('event-date').to_s
          time      = event.get_text('event-time').to_s
          zone      = event.get_text('event-time-zone').to_s
          timestamp = DateTime.parse("#{date} #{time} #{zone}")
          time      = Time.utc(timestamp.utc.year, timestamp.utc.month, timestamp.utc.day, timestamp.utc.hour, timestamp.utc.min, timestamp.utc.sec)
          message   = event.get_text('event-description').to_s
          location  = [event.get_text('event-retail-name'), event.get_text('event-site'), event.get_text('event-province')].compact.join(", ")
          name      = event.get_text('event-identifier').to_s          
          ShipmentEvent.new(name, time, location, message)
        end
      end


      # shipping

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


      def parse_shipping_response(response)
      end

      def parse_shipping_error_response(body)
      end

      def error_response(response, response_klass)
        doc = REXML::Document.new(response)
        messages = doc.elements['messages'].elements.collect('message') {|node| node }
        message = messages.map {|message| message.get_text('description').to_s }.join(", ")
        response_klass.new(false, message, {}, {})
      end

      def log(msg)
        logger.debug(msg) if logger
      end

      private

      def encoded_authorization
        "Basic %s" % ActiveSupport::Base64.encode64("#{@options[:api_key]}:#{@options[:secret]}")
      end
      

      def customer_number_node(options)
        XmlNode.new("customer-number", options[:customer_number])
      end

      def contract_id_node(options)
        XmlNode.new("contract-id", options[:contract_id]) if options[:contract_id]
      end

      def quote_type_node(options)
        XmlNode.new("quote-type", 'commerical')
      end

      def parcel_node(line_items, options ={})
        weight = line_items.sum(&:kilograms).to_f
        XmlNode.new('parcel-characteristics') do |el|
          el << XmlNode.new('weight', "%#2.3f" % weight)
          el << XmlNode.new('mailing-tube', true) if line_items.any?(&:tube?)
          el << XmlNode.new('oversized', true) if line_items.any?(&:oversized?)
          el << XmlNode.new('unpackaged', true) if line_items.any?(&:unpackaged?)
        end
      end

      def origin_node(location_hash)
        origin = Location.new(sanitize_zip(location_hash))
        XmlNode.new("origin-postal-code", origin.zip)
      end

      def destination_node(location_hash)
        destination = Location.new(sanitize_zip(location_hash))
        case destination.country_code
          when 'CA'
            XmlNode.new('destination') do |node|
              node << XmlNode.new('domestic') do |x|
                x << XmlNode.new('postal-code', destination.postal_code)
              end
            end

          when 'US'
            XmlNode.new('destination') do |node|
              node << XmlNode.new('united-states') do |x|
                x << XmlNode.new('zip-code', destination.postal_code)
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

      def shipping_options_node(options = {})
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


      
      def expected_date_from_node(node)
        if service = node.elements['service-standard']
          expected_date = service.get_text("expected-delivery-date").to_s
        else
          expected_date = nil
        end
      end

      def sanitize_zip(hash)
        [:postal_code, :zip].each do |attr|
          hash[attr].gsub!(/\s+/,'') if hash[attr]
        end
        hash
      end
    end
    
    class CPPWSTrackingResponse < TrackingResponse      
      attr_reader :service_name, :expected_date, :changed_date, :change_reason, :customer_number
      
      def initialize(success, message, params = {}, options = {})
        super
        @service_name    = options[:service_name]
        @expected_date   = options[:expected_date]
        @changed_date    = options[:changed_date]
        @change_reason   = options[:change_reason]
        @customer_number = options[:customer_number]
      end
    end
    class InvalidPinFormatError < StandardError; end
    class MissingCustomerNumberError < StandardError; end

  end
end
