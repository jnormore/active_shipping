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

      SHIPMENT_MIMETYPE = "application/vnd.cpc.ncshipment+xml"
      RATE_MIMETYPE = "application/vnd.cpc.ship.rate+xml"
      TRACK_MIMETYPE = "application/vnd.cpc.track+xml"
      
      LANGUAGE = {
        'en' => 'en-CA',
        'fr' => 'fr-CA'
      }
      
      SHIPPING_OPTIONS = [:delivery_confirm, :cod, :cod_amount, :cod_includes_shipping, 
                          :cod_method_of_payment, :insurance, :insurance_amount, 
                          :signature_required, :pa18, :pa19, :hfp, :dns, :lad, :d2po, 
                          :rase, :rts, :aban]

      MAX_WEIGHT = 30 # kg

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
        request  = build_rates_request(origin, destination, line_items, options)
        response = ssl_post(url, request, headers(RATE_MIMETYPE, RATE_MIMETYPE))
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

        response = ssl_get(url, headers(TRACK_MIMETYPE))
        parse_tracking_response(response)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        error_response(response, CPPWSTrackingResponse)
      rescue InvalidPinFormatError => e
        CPPWSTrackingResponse.new(false, "Invalid Pin Format", {}, {:carrier => @@name})
      end
      
      def create_shipment(origin, destination, package, line_items = [], options = {})
        raise MissingCustomerNumberError unless customer_number = options[:customer_number]
        url = endpoint + "rs/#{customer_number}/ncshipment"

        # build shipment request
        request_body = build_shipment_request(origin, destination, package, line_items, options)
        # get response
        response = ssl_post(url, request_body, headers(SHIPMENT_MIMETYPE, SHIPMENT_MIMETYPE))
        parse_shipment_response(response)
      rescue ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError => e
        puts "Error #{e.response.body}"
      rescue MissingCustomerNumberError => e
        p "Error #{e}"
      end
      
      def retrieve_shipping_label(shipping_response, options = {})
        raise MissingShippingNumberError unless shipping_response && shipping_response.shipping_id
        # TODO: do we need to do an initial service call here to get an updated label url? Does the url expire?
        # url = endpoint + "rs/#{customer_number}/ncshipment/#{shipping_response.shipping_id}"
        # response = ssl_post(url, nil, headers(SHIPMENT_MIMETYPE, SHIPMENT_MIMETYPE))
        # shipping_response = parse_shipment_response(response)

        # get label pdf
        return unless shipping_response.label_url
        ssl_get(shipping_response.label_url, headers("application/pdf"))
      end

      
      def maximum_weight
        Mass.new(MAX_WEIGHT, :kilograms)
      end


      # rating

      def build_rates_request(origin, destination, line_items = [], options = {})
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

        shipment_events  = build_tracking_events(events)
        change_date      = root_node.get_text('changed-expected-date').to_s
        expected_date    = root_node.get_text('expected-delivery-date').to_s
        dest_postal_code = root_node.get_text('destination-postal-id').to_s
        destination      = Location.new(:postal_code => dest_postal_code)
        origin           = Location.new({})        
        options = {
          :carrier                 => @@name,
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

      def build_tracking_events(events)
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

      # options
      # :service => 'DOM.EP'
      # :notification_email
      # :packing_instructions
      # :show_postage_rate
      # :cod, :cod_amount, :insurance, :insurance_amount, :signature_required, :pa18, :pa19, :hfp, :dns, :lad
      # 
      def build_shipment_request(origin_hash, destination_hash, package, line_items = [], options = {})
        origin = Location.new(sanitize_zip(origin_hash))
        destination = Location.new(sanitize_zip(destination_hash))

        xml = XmlNode.new('non-contract-shipment', :xmlns => "http://www.canadapost.ca/ws/ncshipment") do |root_node|
          root_node << XmlNode.new('delivery-spec') do |node|
            node << shipment_service_code_node(options)
            node << shipment_sender_node(origin, options)
            node << shipment_destination_node(destination, options)
            node << shipment_options_node(options)
            node << shipment_parcel_node(package)
            node << shipment_notification_node(options)
            node << shipment_preferences_node(options)
            node << references_node(options)             # optional > user defined custom notes
            node << shipment_customs_node(destination, line_items, options)
            # COD Remittance defaults to sender
          end
        end
        xml.to_s
      end

      def shipment_service_code_node(options)
        XmlNode.new('service-code', options[:service])
      end

      def shipment_sender_node(location, options)
        XmlNode.new('sender') do |node|
          node << XmlNode.new('name', location.name)
          node << XmlNode.new('company', location.company) if location.company.present?
          node << XmlNode.new('contact-phone', location.phone)
          node << XmlNode.new('address-details') do |innernode|
            innernode << XmlNode.new('address-line-1', location.address1)
            address2 = [location.address2, location.address3].reject(&:blank?).join(", ")
            innernode << XmlNode.new('address-line-2', address2) unless address2.blank?
            innernode << XmlNode.new('city', location.city)
            innernode << XmlNode.new('prov-state', location.province)     
            #innernode << XmlNode.new('country-code', location.country_code)
            innernode << XmlNode.new('postal-zip-code', location.postal_code)
          end
        end
      end

      def shipment_destination_node(location, options)
        XmlNode.new('destination') do |node|
          node << XmlNode.new('name', location.name)
          node << XmlNode.new('company', location.company) if location.company.present?
          node << XmlNode.new('client-voice-number', location.phone)
          node << XmlNode.new('address-details') do |innernode|
            innernode << XmlNode.new('address-line-1', location.address1)
            address2 = [location.address2, location.address3].reject(&:blank?).join(", ")
            innernode << XmlNode.new('address-line-2', address2) unless address2.blank?
            innernode << XmlNode.new('city', location.city)
            innernode << XmlNode.new('prov-state', location.province)
            innernode << XmlNode.new('country-code', location.country_code)
            innernode << XmlNode.new('postal-zip-code', location.postal_code)
          end
        end
      end

      def shipment_options_node(options)
          shipping_options_node(options)
      end

      def shipment_notification_node(options)
        return unless options[:notification_email]
        XmlNode.new('notification') do |node|
          node << XmlNode.new('email', options[:notification_email])
          node << XmlNode.new('on-shipment', true)
          node << XmlNode.new('on-exception', true)
          node << XmlNode.new('on-delivery', true)
        end
      end

      def shipment_preferences_node(options)
        XmlNode.new('preferences') do |node|
          node << XmlNode.new('show-packing-instructions', options[:packing_instructions] || true)
          node << XmlNode.new('show-postage-rate', options[:show_postage_rate] || false)          
          node << XmlNode.new('show-insured-value', true)
        end
      end

      def references_node(options)
        # custom values
        # XmlNode.new('references') do |node|
        # end
      end

      def shipment_customs_node(destination, line_items, options)
        return unless destination.country_code != 'CA'

        XmlNode.new('customs') do |node|
          # currency of receiving country
          currency = case destination.country_code
            when 'CA' then "CAD"
            when 'US' then "USD"
            else destination.country_code # TODO: country_code != currency code
          end
          node << XmlNode.new('currency',currency)
          # node << XmlNode.new('conversion-from-cad','1') # TODO: do we have exchange rates? Requied if currency!=CAD
          node << XmlNode.new('reason-for-export','SOG') # SOG - Sale of Goods
          node << XmlNode.new('other-reason',options[:customs_other_reason]) if (options[:customs_reason_for_export] && options[:customs_other_reason])
          node << XmlNode.new('additional-customs-info',options[:customs_addition_info]) if options[:customs_addition_info]
          node << XmlNode.new('sku-list') do |sku|
            line_items.each do |line_item|
              sku << XmlNode.new('item') do |item|
                # item << XmlNode.new('hs-tariff-code', '1234.12.12.12') #(optional)
                item << XmlNode.new('sku', line_item[:product_id]) #(optional)
                item << XmlNode.new('customs-description', line_item[:name])
                item << XmlNode.new('unit-weight', line_item[:grams] * 1000)
                item << XmlNode.new('customs-value-per-unit', line_item[:price])
                item << XmlNode.new('customs-number-of-units', line_item[:quantity])
              end
            end
          end
          
        end
      end

      def shipment_parcel_node(package, options ={})
        weight = package.kilograms.to_f
        XmlNode.new('parcel-characteristics') do |el|
          el << XmlNode.new('weight', "%#2.3f" % weight)
          pkg_dim = package.cm
          if pkg_dim && !pkg_dim.select{|x| x != 0}.empty?
            el << XmlNode.new('dimensions') do |dim|
              dim << XmlNode.new('length', pkg_dim[2]) if pkg_dim.size >= 3
              dim << XmlNode.new('width', pkg_dim[1]) if pkg_dim.size >= 2
              dim << XmlNode.new('height', pkg_dim[0]) if pkg_dim.size >= 1
            end
          end
          el << XmlNode.new('document', false)
          el << XmlNode.new('mailing-tube', package.tube?)
          el << XmlNode.new('oversized', true) if package.oversized?
          el << XmlNode.new('unpackaged', package.unpackaged?)
        end
      end


      def parse_shipment_response(response)
        doc = REXML::Document.new(response)
        raise ActiveMerchant::Shipping::ResponseError, "No Shipping" unless root_node = doc.elements['non-contract-shipment-info']      
        options = {
          :shipping_id      => root_node.get_text('shipment-id').to_s,
          :tracking_number  => root_node.get_text('tracking-pin').to_s,
          :details_url      => root_node.elements["links/link[@rel='details']"].attributes['href'],
          :label_url        => root_node.elements["links/link[@rel='label']"].attributes['href'],
          :receipt_url      => root_node.elements["links/link[@rel='receipt']"].attributes['href']
        }
        CPPWSShippingResponse.new(true, "", {}, options)
      end

      def error_response(response, response_klass)
        doc = REXML::Document.new(response)
        messages = doc.elements['messages'].elements.collect('message') {|node| node }
        message = messages.map {|message| message.get_text('description').to_s }.join(", ")
        response_klass.new(false, message, {}, {:carrier => @@name})
      end

      def log(msg)
        logger.debug(msg) if logger
      end

      private

      def encoded_authorization
        "Basic %s" % ActiveSupport::Base64.encode64("#{@options[:api_key]}:#{@options[:secret]}")
      end
      
      def headers(accept = nil, content_type = nil)
        headers = {
          'Authorization'   => encoded_authorization,
          'Accept-Language' => language          
        }
        headers['Accept'] = accept if accept
        headers['Content-Type'] = content_type if content_type
        headers
      end

      def customer_number_node(options)
        XmlNode.new("customer-number", options[:customer_number])
      end

      def contract_id_node(options)
        XmlNode.new("contract-id", options[:contract_id]) if options[:contract_id]
      end

      def quote_type_node(options)
        XmlNode.new("quote-type", 'commercial')
      end

      def parcel_node(line_items, options ={})
        weight = line_items.sum(&:kilograms).to_f
        XmlNode.new('parcel-characteristics') do |el|
          el << XmlNode.new('weight', "%#2.3f" % weight)
          # currently not provided, and not required for rating
          # el << XmlNode.new('dimensions') do |dim|
          #   dim << XmlNode.new('length', 25)
          #   dim << XmlNode.new('width', 25)
          #   dim << XmlNode.new('height', 25)
          # end
          # el << XmlNode.new('document', false)
          el << XmlNode.new('mailing-tube', line_items.any?(&:tube?))
          el << XmlNode.new('oversized', true) if line_items.any?(&:oversized?)
          el << XmlNode.new('unpackaged', line_items.any?(&:unpackaged?))
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

      # TODO: should we do CP defined required field validation here?
      def shipping_options_node(options = {})
        return if (options.keys & SHIPPING_OPTIONS).empty?
        XmlNode.new('options') do |el|
          
          if options[:delivery_confirm]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'DC')
            end
          end

          if options[:cod] && options[:cod_amount]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'COD')
              opt << XmlNode.new('option-amount', options[:cod_amount])
              opt << XmlNode.new('option-qualifier-1', options[:cod_includes_shipping]) if options[:cod_includes_shipping]
              opt << XmlNode.new('option-qualifier-2', options[:cod_method_of_payment]) if options[:cod_method_of_payment]
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

          if options[:d2po]
            el << XmlNode.new('option') do |opt|
              opt << XmlNode.new('option-code', 'D2PO')
              # TODO: what else is required here?
            end
          end

          [:pa18, :pa19, :hfp, :dns, :lad, :rase, :rts, :aban].each do |code|
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

    class CPPWSShippingResponse < ShippingResponse
      attr_reader :label_url, :details_url, :receipt_url
      def initialize(success, message, params = {}, options = {})
        super
        @label_url      = options[:label_url]
        @details_url    = options[:details_url]
        @receipt_url    = options[:receipt_url]
      end
    end

    # custom errors
    class InvalidPinFormatError < StandardError; end
    class MissingCustomerNumberError < StandardError; end
    class MissingShippingNumberError < StandardError; end

  end
end
