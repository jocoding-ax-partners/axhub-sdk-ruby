# frozen_string_literal: true

module AxHub
  module Data
    # Offset pagination helpers (subset of node core pagination that the data
    # ergonomic layer depends on).
    #
    # Ported: serialize_order_by / normalize_order_by, is_v2_cursor,
    # MAX_CURSOR_TOKEN_LENGTH, list_all, and the PaginatedList / ListAllItem
    # result shapes. Keyset encode/decode is intentionally NOT ported: the live
    # AX Hub data API is offset-only, so the data layer only needs the order-by
    # normalizer and the cursor-shape guards used to reject legacy keyset tokens.
    MAX_CURSOR_TOKEN_LENGTH = 4096

    PaginatedList = Struct.new(
      :items, :next_cursor, :first_cursor, :has_next, :has_prev, :total, :total_is_exact,
      keyword_init: true
    )

    # Either an item (type == :item) or a drift marker (type == :drift) when the
    # backend total grows mid-scan.
    ListAllItem = Struct.new(:type, :value, :added_since, keyword_init: true) do
      def initialize(type:, value: nil, added_since: 0)
        super(type: type, value: value, added_since: added_since)
      end
    end

    module_function

    # order_by = String | Array<{ field: String, dir?: "asc"|"desc" }>
    def normalize_order_by(order_by)
      if order_by.is_a?(String)
        fields = []
        order_by.split(',').each do |part|
          trimmed = part.strip
          f = if trimmed.start_with?('-')
                { 'field' => trimmed[1..], 'dir' => 'desc' }
              elsif trimmed.start_with?('+')
                { 'field' => trimmed[1..], 'dir' => 'asc' }
              else
                { 'field' => trimmed, 'dir' => 'asc' }
              end
          fields << f unless f['field'].nil? || f['field'].empty?
        end
      elsif order_by && !order_by.empty?
        fields = order_by.map do |p|
          h = p.transform_keys(&:to_s)
          { 'field' => h['field'], 'dir' => h.fetch('dir', 'asc') }
        end
      else
        fields = []
      end
      if !fields.empty? && fields.none? { |f| f['field'] == 'id' }
        fields << { 'field' => 'id', 'dir' => 'asc' }
      end
      fields
    end

    def serialize_order_by(order_by)
      normalized = normalize_order_by(order_by)
      return (order_by.is_a?(String) ? order_by : nil) if normalized.empty?

      normalized.map { |f| "#{f['dir'] == 'desc' ? '-' : ''}#{f['field']}" }.join(',')
    end

    def is_v2_cursor(token)
      token.is_a?(String) && token.start_with?('v2:')
    end

    # Drive a paginated fetcher to exhaustion, yielding each item and a drift
    # marker when the backend total grows mid-iteration (mirrors node listAll).
    # Returns an Enumerator when no block is given (idiomatic Ruby).
    def list_all(fetcher, opts = {})
      return enum_for(:list_all, fetcher, opts) unless block_given?

      cursor = opts[:cursor]
      initial_total = nil
      last_total = nil
      loop do
        page = fetcher.call(page_size: opts[:page_size], cursor: cursor)
        unless page.total.nil?
          if initial_total.nil?
            initial_total = page.total
            last_total = page.total
          else
            base = last_total.nil? ? initial_total : last_total
            if page.total > base
              yield ListAllItem.new(type: :drift, added_since: page.total - base)
              last_total = page.total
            end
          end
        end
        page.items.each { |item| yield ListAllItem.new(type: :item, value: item) }
        return if page.next_cursor.nil?

        cursor = page.next_cursor
      end
    end
  end
end
