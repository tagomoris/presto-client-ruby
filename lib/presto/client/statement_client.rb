#
# Presto client for Ruby
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Presto::Client

  require 'multi_json'
  require 'presto/client/models'

  module PrestoHeaders
    PRESTO_USER = "X-Presto-User"
    PRESTO_SOURCE = "X-Presto-Source"
    PRESTO_CATALOG = "X-Presto-Catalog"
    PRESTO_SCHEMA = "X-Presto-Schema"

    PRESTO_CURRENT_STATE = "X-Presto-Current-State"
    PRESTO_MAX_WAIT = "X-Presto-Max-Wait"
    PRESTO_MAX_SIZE = "X-Presto-Max-Size"
    PRESTO_PAGE_SEQUENCE_ID = "X-Presto-Page-Sequence-Id"
  end

  class StatementClient
    HEADERS = {
      "User-Agent" => "presto-ruby/#{VERSION}"
    }

    def initialize(faraday, session, query)
      @faraday = faraday
      @faraday.headers.merge!(HEADERS)

      @session = session
      @query = query
      @closed = false
      @exception = nil
      post_query_request!
    end

    def post_query_request!
      response = @faraday.post do |req|
        req.url "/v1/statement"

        if v = @session.user
          req.headers[PrestoHeaders::PRESTO_USER] = v
        end
        if v = @session.source
          req.headers[PrestoHeaders::PRESTO_SOURCE] = v
        end
        if v = @session.catalog
          req.headers[PrestoHeaders::PRESTO_CATALOG] = v
        end
        if v = @session.schema
          req.headers[PrestoHeaders::PRESTO_SCHEMA] = v
        end

        req.body = @query
      end

      # TODO error handling
      if response.status != 200
        raise "Failed to start query: #{response.body}"  # TODO error class
      end

      body = response.body
      hash = MultiJson.load(body)
      @results = QueryResults.decode_hash(hash)
    end

    private :post_query_request!

    attr_reader :query

    def debug?
      @session.debug?
    end

    def closed?
      @closed
    end

    attr_reader :exception

    def exception?
      @exception
    end

    def query_failed?
      @results.error != nil
    end

    def query_succeeded?
      @results.error == nil && !@exception && !@closed
    end

    def current_results
      @results
    end

    def has_next?
      !!@results.next_uri
    end

    def advance
      if closed? || !has_next?
        return false
      end
      uri = @results.next_uri

      start = Time.now
      attempts = 0

      begin
        begin
          response = @faraday.get do |req|
            req.url uri
          end
        rescue => e
          @exception = e
          raise @exception
        end

        if response.status == 200 && !response.body.to_s.empty?
          @results = QueryResults.decode_hash(MultiJson.load(response.body))
          return true
        end

        if response.status != 503  # retry on 503 Service Unavailable
          # deterministic error
          @exception = StandardError.new("Error fetching next at #{uri} returned #{response.status}: #{response.body}")  # TODO error class
          raise @exception
        end

        attempts += 1
        sleep attempts * 0.1
      end while (Time.now - start) < 2*60*60 && !@closed

      @exception = StandardError.new("Error fetching next")  # TODO error class
      raise @exception
    end

    def close
      return if @closed

      # cancel running statement
      if uri = @results.next_uri
        # TODO error handling
        # TODO make async reqeust and ignore response
        @faraday.delete do |req|
          req.url uri
        end
      end

      @closed = true
      nil
    end
  end

end
