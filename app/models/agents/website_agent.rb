require 'nokogiri'
require 'date'
require 'json'
require 'pg'

module Agents
  class WebsiteAgent < Agent
    include WebRequestConcern

    can_dry_run!
    can_order_created_events!
    no_bulk_receive!

    default_schedule "every_12h"

    UNIQUENESS_LOOK_BACK = 200
    UNIQUENESS_FACTOR = 3

    description <<-MD
      The Website Agent scrapes a website, XML document, or JSON feed and creates Events based on the results.

      Specify a `url` and select a `mode` for when to create Events based on the scraped data, either `all`, `on_change`, or `merge` (if fetching based on an Event, see below).

      The `url` option can be a single url, or an array of urls (for example, for multiple pages with the exact same structure but different content to scrape). Set optional post_body to use POST instead of GET.

      The WebsiteAgent can also scrape based on incoming events.

      * Set the `url_from_event` option to a [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) template to generate the url to access based on the Event.  (To fetch the url in the Event's `url` key, for example, set `url_from_event` to `{{ url }}`.)
      * Alternatively, set `data_from_event` to a [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) template to use data directly without fetching any URL.  (For example, set it to `{{ html }}` to use HTML contained in the `html` key of the incoming Event.)
      * If you specify `merge` for the `mode` option, Huginn will retain the old payload and update it with new values.

      # Supported Document Types

      The `type` value can be `xml`, `html`, `json`, or `text`.

      To tell the Agent how to parse the content, specify `extract` as a hash with keys naming the extractions and values of hashes.

      Note that for all of the formats, whatever you extract MUST have the same number of matches for each extractor except when it has `repeat` set to true.  E.g., if you're extracting rows, all extractors must match all rows.  For generating CSS selectors, something like [SelectorGadget](http://selectorgadget.com) may be helpful.

      For extractors with `hidden` set to true, they will be excluded from the payloads of events created by the Agent, but can be used and interpolated in the `template` option explained below.

      For extractors with `repeat` set to true, their first matches will be included in all extracts.  This is useful such as when you want to include the title of a page in all events created from the page.

      # Scraping HTML and XML

      When parsing HTML or XML, these sub-hashes specify how each extraction should be done.  The Agent first selects a node set from the document for each extraction key by evaluating either a CSS selector in `css` or an XPath expression in `xpath`.  It then evaluates an XPath expression in `value` (default: `.`) on each node in the node set, converting the result into a string.  Here's an example:

          "extract": {
            "url": { "css": "#comic img", "value": "@src" },
            "title": { "css": "#comic img", "value": "@title" },
            "body_text": { "css": "div.main", "value": "string(.)" },
            "page_title": { "css": "title", "value": "string(.)", "repeat": true }
          }
      or
          "extract": {
            "url": { "xpath": "//*[@class="blog-item"]/a/@href", "value": "."
            "title": { "xpath": "//*[@class="blog-item"]/a", "value": "normalize-space(.)" },
            "description": { "xpath": "//*[@class="blog-item"]/div[0]", "value": "string(.)" }
          }

      "@_attr_" is the XPath expression to extract the value of an attribute named _attr_ from a node (such as "@href" from a hyperlink), and `string(.)` gives a string with all the enclosed text nodes concatenated without entity escaping (such as `&amp;`). To extract the innerHTML, use `./node()`; and to extract the outer HTML, use `.`.

      You can also use [XPath functions](https://www.w3.org/TR/xpath/#section-String-Functions) like `normalize-space` to strip and squeeze whitespace, `substring-after` to extract part of a text, and `translate` to remove commas from formatted numbers, etc.  Instead of passing `string(.)` to these functions, you can just pass `.` like `normalize-space(.)` and `translate(., ',', '')`.

      Beware that when parsing an XML document (i.e. `type` is `xml`) using `xpath` expressions, all namespaces are stripped from the document unless the top-level option `use_namespaces` is set to `true`.

      For extraction with `array` set to true, all matches will be extracted into an array. This is useful when extracting list elements or multiple parts of a website that can only be matched with the same selector.

      # Scraping JSON

      When parsing JSON, these sub-hashes specify [JSONPaths](http://goessner.net/articles/JsonPath/) to the values that you care about.

      Sample incoming event:

          { "results": {
              "data": [
                {
                  "title": "Lorem ipsum 1",
                  "description": "Aliquam pharetra leo ipsum."
                  "price": 8.95
                },
                {
                  "title": "Lorem ipsum 2",
                  "description": "Suspendisse a pulvinar lacus."
                  "price": 12.99
                },
                {
                  "title": "Lorem ipsum 3",
                  "description": "Praesent ac arcu tellus."
                  "price": 8.99
                }
              ]
            }
          }

      Sample rule:

          "extract": {
            "title": { "path": "results.data[*].title" },
            "description": { "path": "results.data[*].description" }
          }

      In this example the `*` wildcard character makes the parser to iterate through all items of the `data` array. Three events will be created as a result.

      Sample outgoing events:

          [
            {
              "title": "Lorem ipsum 1",
              "description": "Aliquam pharetra leo ipsum."
            },
            {
              "title": "Lorem ipsum 2",
              "description": "Suspendisse a pulvinar lacus."
            },
            {
              "title": "Lorem ipsum 3",
              "description": "Praesent ac arcu tellus."
            }
          ]


      The `extract` option can be skipped for the JSON type, causing the full JSON response to be returned.

      # Scraping Text

      When parsing text, each sub-hash should contain a `regexp` and `index`.  Output text is matched against the regular expression repeatedly from the beginning through to the end, collecting a captured group specified by `index` in each match.  Each index should be either an integer or a string name which corresponds to <code>(?&lt;<em>name</em>&gt;...)</code>.  For example, to parse lines of <code><em>word</em>: <em>definition</em></code>, the following should work:

          "extract": {
            "word": { "regexp": "^(.+?): (.+)$", "index": 1 },
            "definition": { "regexp": "^(.+?): (.+)$", "index": 2 }
          }

      Or if you prefer names to numbers for index:

          "extract": {
            "word": { "regexp": "^(?<word>.+?): (?<definition>.+)$", "index": "word" },
            "definition": { "regexp": "^(?<word>.+?): (?<definition>.+)$", "index": "definition" }
          }

      To extract the whole content as one event:

          "extract": {
            "content": { "regexp": "\\A(?m:.)*\\z", "index": 0 }
          }

      Beware that `.` does not match the newline character (LF) unless the `m` flag is in effect, and `^`/`$` basically match every line beginning/end.  See [this document](http://ruby-doc.org/core-#{RUBY_VERSION}/doc/regexp_rdoc.html) to learn the regular expression variant used in this service.

      # General Options

      Can be configured to use HTTP basic auth by including the `basic_auth` parameter with `"username:password"`, or `["username", "password"]`.

      Set `expected_update_period_in_days` to the maximum amount of time that you'd expect to pass between Events being created by this Agent.  This is only used to set the "working" status.

      Set `uniqueness_look_back` to limit the number of events checked for uniqueness (typically for performance).  This defaults to the larger of #{UNIQUENESS_LOOK_BACK} or #{UNIQUENESS_FACTOR}x the number of detected received results.

      Set `force_encoding` to an encoding name (such as `UTF-8` and `ISO-8859-1`) if the website is known to respond with a missing, invalid, or wrong charset in the Content-Type header.  Below are the steps used by Huginn to detect the encoding of fetched content:

      1. If `force_encoding` is given, that value is used.
      2. If the Content-Type header contains a charset parameter, that value is used.
      3. When `type` is `html` or `xml`, Huginn checks for the presence of a BOM, XML declaration with attribute "encoding", or an HTML meta tag with charset information, and uses that if found.
      4. Huginn falls back to UTF-8 (not ISO-8859-1).

      Set `user_agent` to a custom User-Agent name if the website does not like the default value (`#{default_user_agent}`).

      The `headers` field is optional.  When present, it should be a hash of headers to send with the request.

      Set `disable_ssl_verification` to `true` to disable ssl verification.

      Set `unzip` to `gzip` to inflate the resource using gzip.

      Set `http_success_codes` to an array of status codes (e.g., `[404, 422]`) to treat HTTP response codes beyond 200 as successes.

      If a `template` option is given, its value must be a hash, whose key-value pairs are interpolated after extraction for each iteration and merged with the payload.  In the template, keys of extracted data can be interpolated, and some additional variables are also available as explained in the next section.  For example:

          "template": {
            "url": "{{ url | to_uri: _response_.url }}",
            "description": "{{ body_text }}",
            "last_modified": "{{ _response_.headers.Last-Modified | date: '%FT%T' }}"
          }

      In the `on_change` mode, change is detected based on the resulted event payload after applying this option.  If you want to add some keys to each event but ignore any change in them, set `mode` to `all` and put a DeDuplicationAgent downstream. If you want to limit the keys used for the event comparison set uniqueness_keys array.

      Set `aggregate_events` to emit a single digest event:

          {
            "digest": true,
            "events": [
              {
                "payload": {
                  ...
                }
              },
              {
                "payload": {
                  ...
                }
              }
            ]
          }

      # Liquid Templating

      In [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) templating, the following variables are available:

      * `_url_`: The URL specified to fetch the content from.  When parsing `data_from_event`, this is not set.

      * `_response_`: A response object with the following keys:

          * `status`: HTTP status as integer. (Almost always 200)  When parsing `data_from_event`, this is set to the value of the `status` key in the incoming Event, if it is a number or a string convertible to an integer.

          * `headers`: Response headers; for example, `{{ _response_.headers.Content-Type }}` expands to the value of the Content-Type header.  Keys are insensitive to cases and -/_.  When parsing `data_from_event`, this is constructed from the value of the `headers` key in the incoming Event, if it is a hash.

          * `url`: The final URL of the fetched page, following redirects.  When parsing `data_from_event`, this is set to the value of the `url` key in the incoming Event.  Using this in the `template` option, you can resolve relative URLs extracted from a document like `{{ link | to_uri: _response_.url }}` and `{{ content | rebase_hrefs: _response_.url }}`.

      # Ordering Events

      #{description_events_order}
    MD

    event_description do
      if keys = event_keys
        "Events will have the following fields:\n\n    %s" % [
          Utils.pretty_print(Hash[event_keys.map { |key|
                                    [key, "..."]
                                  }])
        ]
      else
        "Events will be the raw JSON returned by the URL."
      end
    end

    def event_keys
      extract = options['extract'] or return nil

      extract.each_with_object([]) { |(key, value), keys|
        keys << key unless boolify(value['hidden'])
      } | (options['template'].presence.try!(:keys) || [])
    end

    def working?
      event_created_within?(options['expected_update_period_in_days']) && !recent_error_logs?
    end

    def default_options
      {
          'expected_update_period_in_days' => "2",
          'url' => "https://xkcd.com",
          'type' => "html",
          'mode' => "on_change",
          'extract' => {
            'url' => { 'css' => "#comic img", 'value' => "@src" },
            'title' => { 'css' => "#comic img", 'value' => "@alt" },
            'hovertext' => { 'css' => "#comic img", 'value' => "@title" }
          }
      }
    end

    def validate_options
      # Check for required fields
      errors.add(:base, "either url, url_from_event, or data_from_event are required") unless options['url'].present? || options['url_from_event'].present? || options['data_from_event'].present?
      errors.add(:base, "expected_update_period_in_days is required") unless options['expected_update_period_in_days'].present?
      validate_extract_options!
      validate_template_options!
      validate_http_success_codes!

      # Check for optional fields
      if options['mode'].present?
        errors.add(:base, "mode must be set to on_change, all or merge") unless %w[on_change all merge].include?(options['mode'])
      end

      if options['expected_update_period_in_days'].present?
        errors.add(:base, "Invalid expected_update_period_in_days format") unless is_positive_integer?(options['expected_update_period_in_days'])
      end

      if options['uniqueness_look_back'].present?
        errors.add(:base, "Invalid uniqueness_look_back format") unless is_positive_integer?(options['uniqueness_look_back'])
      end

      validate_web_request_options!
    end

    def validate_http_success_codes!
      consider_success = options["http_success_codes"]
      if consider_success.present?

        if (consider_success.class != Array)
          errors.add(:http_success_codes, "must be an array and specify at least one status code")
        else
          if consider_success.uniq.count != consider_success.count
            errors.add(:http_success_codes, "duplicate http code found")
          else
            if consider_success.any?{|e| e.to_s !~ /^\d+$/ }
              errors.add(:http_success_codes, "please make sure to use only numeric values for code, ex 404, or \"404\"")
            end
          end
        end

      end
    end

    def validate_extract_options!
      extraction_type = (extraction_type() rescue extraction_type(options))
      case extract = options['extract']
      when Hash
        if extract.each_value.any? { |value| !value.is_a?(Hash) }
          errors.add(:base, 'extract must be a hash of hashes.')
        else
          case extraction_type
          when 'html', 'xml'
            extract.each do |name, details|
              case details['css']
              when String
                # ok
              when nil
                case details['xpath']
                when String
                  # ok
                when nil
                  errors.add(:base, "When type is html or xml, all extractions must have a css or xpath attribute (bad extraction details for #{name.inspect})")
                else
                  errors.add(:base, "Wrong type of \"xpath\" value in extraction details for #{name.inspect}")
                end
              else
                errors.add(:base, "Wrong type of \"css\" value in extraction details for #{name.inspect}")
              end

              case details['value']
              when String, nil
                # ok
              else
                errors.add(:base, "Wrong type of \"value\" value in extraction details for #{name.inspect}")
              end
            end
          when 'json'
            extract.each do |name, details|
              case details['path']
              when String
                # ok
              when nil
                errors.add(:base, "When type is json, all extractions must have a path attribute (bad extraction details for #{name.inspect})")
              else
                errors.add(:base, "Wrong type of \"path\" value in extraction details for #{name.inspect}")
              end
            end
          when 'text'
            extract.each do |name, details|
              case regexp = details['regexp']
              when String
                begin
                  re = Regexp.new(regexp)
                rescue => e
                  errors.add(:base, "invalid regexp for #{name.inspect}: #{e.message}")
                end
              when nil
                errors.add(:base, "When type is text, all extractions must have a regexp attribute (bad extraction details for #{name.inspect})")
              else
                errors.add(:base, "Wrong type of \"regexp\" value in extraction details for #{name.inspect}")
              end

              case index = details['index']
              when Integer, /\A\d+\z/
                # ok
              when String
                if re && !re.names.include?(index)
                  errors.add(:base, "no named capture #{index.inspect} found in regexp for #{name.inspect})")
                end
              when nil
                errors.add(:base, "When type is text, all extractions must have an index attribute (bad extraction details for #{name.inspect})")
              else
                errors.add(:base, "Wrong type of \"index\" value in extraction details for #{name.inspect}")
              end
            end
          when /\{/
            # Liquid templating
          else
            errors.add(:base, "Unknown extraction type #{extraction_type.inspect}")
          end
        end
      when nil
        unless extraction_type == 'json'
          errors.add(:base, 'extract is required for all types except json')
        end
      else
        errors.add(:base, 'extract must be a hash')
      end
    end

    def validate_template_options!
      template = options['template'].presence or return

      unless Hash === template &&
             template.each_pair.all? { |key, value| String === value }
        errors.add(:base, 'template must be a hash of strings.')
      end
    end

    def check
      check_urls(interpolated['url'], options['post_body'])
    end

    def check_urls(in_url, in_post_body = '', existing_payload = {})
      return unless in_url.present?

      post_bodies = Array(in_post_body)
      events_buffer = []
      Array(in_url).each_with_index { |url, i |
        check_url(url, post_bodies[i], existing_payload, events_buffer)
      }
      events_buffer = compact_events(events_buffer, options['compact_keys']) if options['compact_keys'].present?
      events_buffer = events_buffer.select {|event| eval(options['filter_callback']) } if options['filter_callback'].present?
      flush_events(events_buffer)
    end

    def check_url(url, post_body, existing_payload = {}, events_buffer)
      uri = Utils.normalize_uri(url)
      if uri.to_s.start_with?("postgresql://")
        query_body = post_body[:query].to_s
      elsif post_body.present?
        query_body = post_body.is_a?(Hash) ? JSON.generate(post_body).to_s : post_body
      else
        query_body = ''
      end
      if query_body.present?
        interpolation_context.stack {
          interpolation_context['events_buffer'] = events_buffer.map { |e| e[:payload]}
          query_body = interpolate_string(query_body)
        }
      end
      log "Fetching #{uri}\n#{query_body}"

      if uri.to_s.start_with?("postgresql://")
        response = {status: 200, headers: {}, body: []}
        get_pg_connection(uri.to_s).exec(query_body) do |result|
          result.each do |row|
            response[:body] << row
          end
        end
        interpolation_context.stack {
          interpolation_context['_url_'] = uri.to_s
          interpolation_context['_response_'] = response
          handle_data(response[:body].to_json, uri.to_s, existing_payload, events_buffer)
        }
      else
        response = query_body.blank? ? faraday.get(uri) : faraday.post(uri, query_body)
        raise "Failed: #{response.inspect}" unless consider_response_successful?(response)
        log "Response #{response.body}"
        interpolation_context.stack {
          interpolation_context['_url_'] = uri.to_s
          interpolation_context['_response_'] = ResponseDrop.new(response)
          handle_data(response.body, response.env[:url], existing_payload, events_buffer)
        }
      end
    rescue => e
      error "Error when fetching url: #{e.message}\n#{e.backtrace.join("\n")}"
    end

    def get_pg_connection(connection_string)
      begin
        need_reconnect = @pg_connection.blank? || @pg_connection_string.blank? ||
            @pg_connection_string != connection_string || @pg_connection.status != PG::CONNECTION_OK
        @pg_connection.close if need_reconnect && @pg_connection.present?
      rescue
        need_reconnect = true
      end
      if need_reconnect
        @pg_connection_string = connection_string
        @pg_connection = PG.connect(connection_string)
      end
      @pg_connection
    end

    def default_encoding
      case extraction_type
      when 'html', 'xml'
        # Let Nokogiri detect the encoding
        nil
      else
        super
      end
    end

    def handle_data(body, url, existing_payload, events_buffer)
      # Beware, url may be a URI object, string or nil

      doc = parse(body)

      if extract_full_json?
        if doc.is_a?(Array)
          doc.each do |e|
            emit_event(existing_payload.merge(e), events_buffer) if store_payload!(previous_payloads(1), e)
          end
        else
          emit_event(existing_payload.merge(doc), events_buffer) if store_payload!(previous_payloads(1), doc)
        end
        return
      end

      output =
        case extraction_type
          when 'json'
            extract_json(doc)
          when 'text'
            extract_text(doc)
          else
            extract_xml(doc)
        end

      num_tuples = output.size or
        raise "At least one non-repeat key is required"

      old_events = previous_payloads num_tuples

      template = options['template'].presence

      output.each do |extracted|
        result = extracted.except(*output.hidden_keys)

        if template
          result.update(interpolate_options(template, extracted))
        end

        if store_payload!(old_events, result)
          log "Storing new parsed result for '#{name}': #{result.inspect}"
          emit_event(existing_payload.merge(result), events_buffer)
        end
      end
    end

    def emit_event(payload, buffer)
      # log "Raw event for '#{name}': #{payload.inspect}"
      payload = payload.merge(options['extra_payload']) if options['extra_payload'].present?
      buffer << {payload: payload}
    end

    def flush_events(buffer)
      return if buffer.blank?
      if options['aggregate_events'].present? && options['aggregate_events'] != 'false'
        buffer.each_slice(interpolated['aggregate_limit'] || 10) do |sub_buffer|
          digest = {digest: true, events: sub_buffer}
          digest = digest.merge(options['digest_extra_payload']) if options['digest_extra_payload'].present?
          create_event payload: digest
        end
      else
        buffer.each { |e| create_event e }
      end
    end

    def compact_events(buffer, keys)
      log "Compacting with #{keys}"
      return buffer.clone if keys.blank?
      buffer
          .map { |event| event[:payload].reject { |key, value| value == 'unknown' } }
          .group_by { |payload| payload.select { |key, value| keys.include?(key) } }
          .map { |key, payloads| {payload: payloads.reduce({}, :merge)} }
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        interpolate_with(event) do
          existing_payload = interpolated['mode'].to_s == "merge" ? event.payload : {}

          if data_from_event = options['data_from_event'].presence
            data = interpolate_options(data_from_event)
            if data.present?
              handle_event_data(data, event, existing_payload)
            else
              error "No data was found in the Event payload using the template #{data_from_event}", inbound_event: event
            end
          else
            url_to_scrape =
              if url_template = options['url_from_event'].presence
                interpolate_options(url_template)
              else
                interpolated['url']
              end
            post_body =
              if body_template = options['post_body_from_event'].presence
                interpolate_options(body_template)
              else
                interpolated['post_body']
              end
            check_urls(url_to_scrape, post_body, existing_payload)
          end
        end
      end
    end

    private
    def consider_response_successful?(response)
      response.success? || begin
        consider_success = options["http_success_codes"]
        consider_success.present? && (consider_success.include?(response.status.to_s) || consider_success.include?(response.status))
      end
    end

    def handle_event_data(data, event, existing_payload)
      events_buffer = []
      interpolation_context.stack {
        interpolation_context['_response_'] = ResponseFromEventDrop.new(event)
        handle_data(data, event.payload['url'].presence, existing_payload, events_buffer)
      }
      flush_events(events_buffer)
    rescue => e
      error "Error when handling event data: #{e.message}\n#{e.backtrace.join("\n")}", inbound_event: event
    end

    # This method returns true if the result should be stored as a new event.
    # If mode is set to 'on_change', this method may return false and update an existing
    # event to expire further in the future.
    def store_payload!(old_events, result)
      case interpolated['mode'].presence
      when 'on_change'
        found = old_events.find { |event|
          if event.payload['digest'].present?
            event.payload['events'].find { |sub_event| is_events_equal(sub_event['payload'], result) }
          else
            is_events_equal(event.payload, result)
          end
        }
        if found
          found.update!(expires_at: new_event_expiration_date)
          false
        else
          true
        end
      when 'all', 'merge', ''
        true
      else
        raise "Illegal options[mode]: #{interpolated['mode']}"
      end
    end

    def is_events_equal(one, two)
      if options['uniqueness_keys'].present?
        one.select{ |key| options['uniqueness_keys'].include? key.to_s } ==
            two.select{ |key| options['uniqueness_keys'].include? key.to_s }
      else
        one.to_json == two.to_json
      end
    end

    def previous_payloads(num_events)
      if interpolated['uniqueness_look_back'].present?
        look_back = interpolated['uniqueness_look_back'].to_i
      else
        # Larger of UNIQUENESS_FACTOR * num_events and UNIQUENESS_LOOK_BACK
        look_back = UNIQUENESS_FACTOR * num_events
        if look_back < UNIQUENESS_LOOK_BACK
          look_back = UNIQUENESS_LOOK_BACK
        end
      end
      events.order("id desc").limit(look_back) if interpolated['mode'] == "on_change"
    end

    def extract_full_json?
      !interpolated['extract'].present? && extraction_type == "json"
    end

    def extraction_type(interpolated = interpolated())
      (interpolated['type'] || begin
        case interpolated['url']
        when /\.(rss|xml)$/i
          "xml"
        when /\.json$/i
          "json"
        when /\.(txt|text)$/i
          "text"
        else
          "html"
        end
      end).to_s
    end

    def use_namespaces?
      if interpolated.key?('use_namespaces')
        boolify(interpolated['use_namespaces'])
      else
        interpolated['extract'].none? { |name, extraction_details|
          extraction_details.key?('xpath')
        }
      end
    end

    def extract_each(&block)
      interpolated['extract'].each_with_object(Output.new) { |(name, extraction_details), output|
        if boolify(extraction_details['repeat'])
          values = Repeater.new { |repeater|
            block.call(extraction_details, repeater)
          }
        else
          values = []
          block.call(extraction_details, values)
        end
        log "Values extracted: #{values}"
        begin
          output[name] = values
        rescue UnevenSizeError
          if interpolated['allow_unequal_values'].blank?
            raise "Got an uneven number of matches for #{interpolated['name']}: #{interpolated['extract'].inspect}"
          end
        else
          output.hidden_keys << name if boolify(extraction_details['hidden'])
        end
      }
    end

    def extract_json(doc)
      extract_each { |extraction_details, values|
        log "Extracting #{extraction_type} at #{extraction_details['path']}"
        Utils.values_at(doc, extraction_details['path']).each { |value|
          values << value
        }
      }
    end

    def extract_text(doc)
      extract_each { |extraction_details, values|
        regexp = Regexp.new(extraction_details['regexp'])
        log "Extracting #{extraction_type} with #{regexp}"
        case index = extraction_details['index']
        when /\A\d+\z/
          index = index.to_i
        end
        doc.scan(regexp) {
          values << Regexp.last_match[index]
        }
      }
    end

    def extract_xml(doc)
      extract_each { |extraction_details, values|
        case
        when css = extraction_details['css']
          nodes = doc.css(css)
        when xpath = extraction_details['xpath']
          nodes = doc.xpath(xpath)
        else
          raise '"css" or "xpath" is required for HTML or XML extraction'
        end
        log "Extracting #{extraction_type} at #{xpath || css}"
        case nodes
        when Nokogiri::XML::NodeSet
          stringified_nodes  = nodes.map do |node|
            case value = node.xpath(extraction_details['value'] || '.')
            when Float
              # Node#xpath() returns any numeric value as float;
              # convert it to integer as appropriate.
              value = value.to_i if value.to_i == value
            end
            value.to_s
          end
          if boolify(extraction_details['array'])
            values << stringified_nodes
          else
            stringified_nodes.each { |n| values << n }
          end
        else
          raise "The result of HTML/XML extraction was not a NodeSet"
        end
      }
    end

    def parse(data)
      case type = extraction_type
      when "xml"
        doc = Nokogiri::XML(data)
        # ignore xmlns, useful when parsing atom feeds
        doc.remove_namespaces! unless use_namespaces?
        doc
      when "json"
        JSON.parse(data)
      when "html"
        Nokogiri::HTML(data)
      when "text"
        data
      else
        raise "Unknown extraction type: #{type}"
      end
    end

    class UnevenSizeError < ArgumentError
    end

    class Output
      def initialize
        @hash = {}
        @size = nil
        @hidden_keys = []
      end

      attr_reader :size
      attr_reader :hidden_keys

      def []=(key, value)
        case size = value.size
        when Integer
          if @size && @size != size
            raise UnevenSizeError, 'got an uneven size'
          end
          @size = size
        end

        @hash[key] = value
      end

      def each
        @size.times.zip(*@hash.values) do |index, *values|
          yield @hash.each_key.lazy.zip(values).to_h
        end
      end
    end

    class Repeater < Enumerator
      # Repeater.new { |y|
      #   # ...
      #   y << value
      # } #=> [value, ...]
      def initialize(&block)
        @value = nil
        super(Float::INFINITY) { |y|
          loop { y << @value }
        }
        catch(@done = Object.new) {
          block.call(self)
        }
      end

      def <<(value)
        @value = value
        throw @done
      end

      def to_s
        "[#{@value.inspect}, ...]"
      end
    end

    # Wraps Faraday::Response
    class ResponseDrop < LiquidDroppable::Drop
      def headers
        HeaderDrop.new(@object.headers)
      end

      # Integer value of HTTP status
      def status
        @object.status
      end

      # The URL
      def url
        @object.env.url.to_s
      end
    end

    class ResponseFromEventDrop < LiquidDroppable::Drop
      def headers
        headers = Faraday::Utils::Headers.from(@object.payload[:headers]) rescue {}

        HeaderDrop.new(headers)
      end

      # Integer value of HTTP status
      def status
        Integer(@object.payload[:status]) rescue nil
      end

      # The URL
      def url
        @object.payload[:url]
      end
    end

    # Wraps Faraday::Utils::Headers
    class HeaderDrop < LiquidDroppable::Drop
      def liquid_method_missing(name)
        @object[name.tr('_', '-')]
      end
    end
  end
end
