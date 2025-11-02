# app/pdfs/required_pdf.rb
# frozen_string_literal: true

require 'prawn'
require 'prawn/templates'

class RequiredPdf < Prawn::Document
  # Use blank template
  TEMPLATE_PATH = Rails.root.join('storage', 'TREC_Template_Blank.pdf').to_s

  DEFAULT_FONT_SIZE = 10
  MIN_FONT_SIZE = 8

  def initialize(params = {})
    # Let template determine page geometry; margin 0 to match template artwork
    super(margin: 0)

    @p = params.with_indifferent_access
    @debug = @p[:debug] == true

    import_template_pages_if_present
    build_pdf
  end

  # Import template pages so page count/geometry match the blank template
  def import_template_pages_if_present
    return unless File.exist?(TEMPLATE_PATH)

    begin
      require 'combine_pdf'
      doc = CombinePDF.load(TEMPLATE_PATH)

      # Create pages for each template page
      start_new_page(template: TEMPLATE_PATH, template_page: 1) rescue nil
      (2..doc.pages.count).each do |i|
        start_new_page(template: TEMPLATE_PATH, template_page: i)
      end
    rescue LoadError
      # combine_pdf not installed - at least ensure first template page is used
      start_new_page(template: TEMPLATE_PATH, template_page: 1) rescue nil
    rescue => e
      Rails.logger.warn "Template import fallback: #{e.class}: #{e.message}" if defined?(Rails)
    end
  end

  def build_pdf
    go_to_page(1)
    debug_grid if @debug

    # Header fields - tune x/top_y/width to match template; these coordinates are a good start
    draw_field_text(x: 80, top_y: 60, width: 260, text: @p[:client_name], size: 12)
    draw_field_text(x: 400, top_y: 60, width: 150, text: format_date(@p[:inspection_date]), size: 10)
    draw_field_text(x: 80, top_y: 90, width: 420, text: @p[:property_address], size: 10)
    draw_field_text(x: 80, top_y: 120, width: 240, text: @p[:inspector_name], size: 10)
    draw_field_text(x: 350, top_y: 120, width: 160, text: @p[:inspector_license], size: 10)

    # Dynamic "observations" block: it will shrink a little to fit or move to next page to avoid overlap
    if @p[:observations].present?
      draw_dynamic_block(x: 80, top_y: 200, width: 420, max_height: 420, text: @p[:observations], size: 10)
    end

    # Images: each item: {path:, page: 1..N, x:, top_y:, fit: [w,h]}
    Array(@p[:images]).each do |img|
      go_to_page(img[:page] || 1)
      place_image_with_check(img)
    end

    # Table example (flowing)
    if @p[:items].present?
      go_to_page(1)
      draw_table_flow(x: 80, top_y: 450, width: 420, rows: table_rows(@p[:items]))
    end

    number_pages "<page> / <total>", at: [bounds.right - 70, 20], align: :right, size: 9
  end

  # ---------- Helpers ----------

  def draw_field_text(x:, top_y:, width:, text:, size: DEFAULT_FONT_SIZE, style: nil, align: :left, height: nil)
    return if text.nil? || text.to_s.strip.empty?
    y = y_from_top(top_y)
    height ||= size * 1.6
    bounding_box([x, y], width: width, height: height) do
      text_box text.to_s, at: [0, bounds.top], width: width, height: height, size: size, style: style, align: align, overflow: :shrink_to_fit
    end
  rescue => e
    # fallback
    draw_text(text.to_s, at: [x, y], size: size) rescue nil
  end

  # Try to fit text: shrink a little, otherwise render on a new page
  def draw_dynamic_block(x:, top_y:, width:, max_height:, text:, size: DEFAULT_FONT_SIZE, min_size: MIN_FONT_SIZE, align: :left)
    return if text.to_s.strip.empty?
    y = y_from_top(top_y)
    remaining_on_page = y - bounds.bottom
    container_height = [remaining_on_page, max_height].min

    curr_size = size
    needed = height_of(text.to_s, width: width, size: curr_size)

    while curr_size > min_size && needed > container_height
      curr_size -= 1
      needed = height_of(text.to_s, width: width, size: curr_size)
    end

    if needed <= container_height
      bounding_box([x, y], width: width, height: needed) do
        text_box text.to_s, at: [0, bounds.top], width: width, height: needed, size: curr_size, align: align
      end
      return
    end

    # still too big -> move whole block to a new page
    start_new_page
    new_y = y_from_top(top_y)
    page_container = new_y - bounds.bottom
    final_size = size
    needed = height_of(text.to_s, width: width, size: final_size)
    while final_size > min_size && needed > page_container
      final_size -= 1
      needed = height_of(text.to_s, width: width, size: final_size)
    end

    bounding_box([x, new_y], width: width, height: needed) do
      text_box text.to_s, at: [0, bounds.top], width: width, height: needed, size: final_size, align: align
    end
  end

  def draw_table_flow(x:, top_y:, width:, rows:)
    y = y_from_top(top_y)
    remaining = y - bounds.bottom

    bounding_box([x, y], width: width, height: remaining) do
      table(rows, header: true, cell_style: {size: 9}) do
        self.column_widths = [40, 260, 60, 60]
      end
    end
  end

  def table_rows(items)
    [["#", "Item", "Qty", "Price"]] + items.each_with_index.map { |it, i| [i + 1, it[:name], it[:qty].to_s, format('%.2f', it[:price])] }
  end

  # Place image with checks so it doesn't overlap other elements
  def place_image_with_check(img)
    path = img[:path].to_s
    return unless File.exist?(path)

    x = img[:x] || 0
    top_y = img[:top_y] || 0
    y = y_from_top(top_y)
    fit = Array(img[:fit]) if img[:fit]

    required_h = (fit && fit[1]) || 200
    remaining = y - bounds.bottom
    start_new_page if required_h > remaining

    opts = { at: [x, y] }
    opts[:fit] = fit if fit
    image(path, opts)
  rescue Prawn::Errors::UnsupportedImageType
    Rails.logger.warn "Unsupported image type: #{path}" if defined?(Rails)
  end

  # Convert top-based Y to prawn bottom-left origin Y (consistent across both classes)
  def y_from_top(top_y)
    bounds.top - top_y
  end

  def format_date(val)
    return "" unless val
    Date.parse(val.to_s).strftime("%B %d, %Y") rescue val.to_s
  end

  # visual debug grid (optional)
  def debug_grid(step: 72)
    transparent(0.6) do
      stroke_color 'cccccc'
      (0..(bounds.right / step).ceil).each do |i|
        x = i * step
        stroke_vertical_line 0, bounds.top, at: x
        draw_text x.to_s, at: [x + 2, bounds.top - 10], size: 6
      end
      (0..(bounds.top / step).ceil).each do |j|
        y = bounds.top - j * step
        stroke_horizontal_line 0, bounds.right, at: y
        draw_text (bounds.top - y).to_s, at: [2, y - 10], size: 6
      end
    end
  end
end
