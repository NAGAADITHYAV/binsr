# app/pdfs/template_pdf.rb
require "prawn/templates"
require "uri"
require "fileutils"
require "open-uri"
require "tempfile"
require "digest"

# Optional: mini_magick for image dimension calculation
begin
  require "mini_magick"
  MINI_MAGICK_AVAILABLE = true
rescue LoadError
  MINI_MAGICK_AVAILABLE = false
  Rails.logger.warn "mini_magick not available - image sizing will use estimates" if defined?(Rails.logger)
end

# silence AFM warning for non-UTF8 fonts if available
Prawn::Fonts::AFM.hide_m17n_warning = true if defined?(Prawn::Fonts::AFM)

class TemplatePdf < Prawn::Document
  # ============================================
  # CONSTANTS - Layout Positioning
  # ============================================
  CONTENT_LEFT   = 80   # Left margin for content (matches template field positions)
  CONTENT_RIGHT  = 40   # Right margin for content
  CONTENT_TOP    = 200  # Start position from top (after header)
  CONTENT_BOTTOM = 60   # Bottom margin for page numbers / footer
  
  # Image sizing constants
  MAX_IMAGE_WIDTH = 492  # Content width (612 - 80 - 40)
  MAX_IMAGE_HEIGHT = 200 # Maximum image height for proper flow
  IMAGE_SPACING_BEFORE = 6
  IMAGE_SPACING_AFTER = 6

  # ============================================
  # INITIALIZATION
  # ============================================
  def initialize(report, options = {})
    template_path = Rails.root.join("storage", "TREC_Template_Blank.pdf")
    if File.exist?(template_path)
      super(template: template_path.to_s, margin: 0)
    else
      super(page_size: "A4", margin: 0)
    end

    @skip_images = options.fetch(:skip_images, false)
    @raw_report = report || {}
    @inspection = @raw_report["inspection"] || @raw_report[:inspection] || @raw_report
    @report = build_report_hash(@inspection)

    start_new_page if page_count == 0

    build_pdf
    safe_add_page_numbers
  end

  # ============================================
  # DATA EXTRACTION
  # ============================================
  def build_report_hash(inspection)
    {
      "client_name" => extract_value(inspection, ["clientInfo", "name"]) || "Data not found in test data",
      "inspection_date" => extract_value(inspection, ["schedule", "date"]),
      "property_address" => extract_value(inspection, ["address", "fullAddress"]) || "Data not found in test data",
      "inspector_name" => extract_value(inspection, ["inspector", "name"]) || "Data not found in test data",
      "inspector_license_number" =>
        extract_value(inspection, ["inspector", "licenseNumber"]) ||
        extract_value(inspection, ["inspector", "license"]) ||
        "Data not found in test data",
      "sponsor_name" => extract_value(inspection, ["sponsor", "name"]) || "Data not found in test data",
      "sponsor_license_number" =>
        extract_value(inspection, ["sponsor", "licenseNumber"]) ||
        extract_value(inspection, ["sponsor", "license"]) ||
        "Data not found in test data",
      "header_image_url" => extract_value(inspection, ["headerImageUrl"]),
      "sections" => extract_value(inspection, ["sections"]) || []
    }
  end

  def extract_value(hash, keys)
    return nil unless hash.is_a?(Hash)
    current = hash
    keys.each do |key|
      current = (current[key] || current[key.to_sym]) if current.is_a?(Hash)
      return nil unless current
    end
    current
  end

  private

  # ============================================
  # MAIN BUILD PROCESS
  # ============================================
  def build_pdf
    safe_ensure_page
    
    # Page 1: Header only
    fill_header_info_on_page(1)
    fill_inspection_details_on_page(1)
    
    # Page 2: Header only (static content from template)
    start_new_page
    fill_header_info_on_page(2)
    
    # Page 3 and onwards: Main content (sections)
    start_new_page
    fill_main_content
  end

  def safe_ensure_page
    return if page_count > 0
    begin
      start_new_page
    rescue => e
      Rails.logger.error "Could not create page: #{e.class}: #{e.message}" if defined?(Rails.logger)
    end
  end

  # ============================================
  # HEADER COMPONENT
  # ============================================
  def fill_header_info_on_page(page_num)
    go_to_page(page_num) rescue nil

    # Header positions matching TREC template
    draw_field_text(x: 80, top_y: 60, width: 260, text: @report["client_name"] || "", size: 10)

    date_text = @report["inspection_date"] ? format_date(@report["inspection_date"]) : "Data not found in test data"
    draw_field_text(x: 400, top_y: 60, width: 150, text: date_text, size: 10)

    draw_field_text(x: 80, top_y: 90, width: 420, text: @report["property_address"] || "", size: 10)

    draw_field_text(x: 80, top_y: 120, width: 240, text: @report["inspector_name"] || "", size: 10)
    draw_field_text(x: 350, top_y: 120, width: 160, text: @report["inspector_license_number"] || "", size: 10)

    draw_field_text(x: 80, top_y: 150, width: 240, text: @report["sponsor_name"] || "", size: 10)
    draw_field_text(x: 350, top_y: 150, width: 160, text: @report["sponsor_license_number"] || "", size: 10)

    formatted_date = @report["inspection_date"] ? format_date(@report["inspection_date"]) : "Data not found in test data"
    report_id = "#{(@report['property_address'] || '')} - #{formatted_date}"
    draw_field_text(x: 80, top_y: 180, width: 420, text: report_id, size: 9, style: :italic)
  rescue => e
    Rails.logger.warn "fill_header_info_on_page(#{page_num}) skipped due to: #{e.message}" if defined?(Rails.logger)
  end

  # ============================================
  # HEADER IMAGE COMPONENT
  # ============================================
  def fill_inspection_details_on_page(page_num)
    return if @skip_images
    go_to_page(page_num) rescue nil
    url = @report["header_image_url"]
    safe_add_image(url, is_header: true) if url.present?
  end

  # ============================================
  # MAIN CONTENT COMPONENT
  # ============================================
  def fill_main_content
    # Ensure we're on page 3 (where main content starts)
    # Pages 1 and 2 are already created with headers
    target_page = 3
    while page_count < target_page
      start_new_page
    end
    
    # Navigate to page 3
    go_to_page(target_page) rescue nil

    # Set initial cursor position for content
    bounds_height = bounds.height rescue 792
    @content_start_y = bounds_height - CONTENT_TOP
    move_cursor_to(@content_start_y)

    sections = @report["sections"] || []
    sections.each { |s| add_section(s) }
  end

  def add_section(section)
    return unless section.is_a?(Hash)
    start_new_page_if_needed(100)
    
    section_name = section["name"] || section["title"]
    section_number = section["sectionNumber"]

    if section_name.present?
      move_down(6) rescue nil
      section_title = section_number.present? ? "#{section_number}. #{section_name}" : section_name.to_s
      add_paragraph(section_title, size: 14, style: :bold, spacing_after: 6)
    end

    (section["lineItems"] || []).each { |li| add_line_item(li, section_number) }
    move_down(10) rescue nil
  end

  def add_line_item(line_item, section_number)
    return unless line_item.is_a?(Hash)
    start_new_page_if_needed(120)

    li_name = line_item["name"] || line_item["title"]
    li_number = line_item["lineItemNumber"]

    if li_name.present?
      move_down(6) rescue nil
      item_title = li_number.present? ? "#{section_number}.#{li_number} #{li_name}" : li_name.to_s
      add_paragraph(item_title, size: 12, style: :bold, spacing_after: 4)
    end

    (line_item["comments"] || []).each { |c| add_comment(c) }
  end

  def add_comment(comment)
    return unless comment.is_a?(Hash)
    start_new_page_if_needed(90)

    label = comment["label"]
    number = comment["commentNumber"]

    if label.present?
      label_text = number.present? ? "#{number} #{label}" : label.to_s
      add_paragraph(label_text, size: 11, style: :bold, spacing_after: 3)
    end

    content = comment["text"] || comment["content"] || comment["commentText"]
    add_paragraph(decode_html_entities(content.to_s)) if content.present?

    # Add photos if present
    photos = comment["photos"] || []
    if photos.is_a?(Array) && photos.any? && !@skip_images
      photos.each do |p|
        url = p.is_a?(String) ? p : (p["url"] rescue nil)
        safe_add_image(url, is_header: false) if url.present?
      end
    end

    videos = comment["videos"] || []
    if videos.is_a?(Array) && videos.any?
      videos.each do |v|
        v_url = v.is_a?(String) ? v : (v["url"] rescue nil)
        add_paragraph("Video: #{v_url}") if v_url.present?
      end
    end

    move_down(6) rescue nil
  end

  # ============================================
  # TEXT RENDERING COMPONENTS
  # ============================================
  def draw_field_text(x:, top_y:, width:, text:, size: 10, style: nil, align: :left, height: nil)
    return if text.nil? || text.to_s.strip.empty?
    y = y_from_top(top_y)
    height ||= size * 1.6
    bounding_box([x, y], width: width, height: height) do
      text_box text.to_s,
               at: [0, bounds.top],
               width: width,
               height: height,
               size: size,
               style: style,
               align: align,
               overflow: :shrink_to_fit
    end
  rescue => e
    begin
      draw_text(text.to_s, at: [x, y], size: size, style: style)
    rescue => _
      Rails.logger.warn "draw_field_text failed: #{e.message}" if defined?(Rails.logger)
    end
  end

  def add_paragraph(text, size: 10, style: nil, spacing_after: 4)
    return if text.nil? || text.to_s.strip.empty?
    safe_ensure_page

    font_size = size
    bounds_width = bounds.width rescue 612
    content_width = bounds_width - CONTENT_LEFT - CONTENT_RIGHT

    current_cursor = cursor rescue nil
    return unless current_cursor

    # Calculate available height from current position to bottom margin
    available_height = current_cursor - CONTENT_BOTTOM
    if available_height < 50
      start_new_page
      bounds_height = bounds.height rescue 792
      @content_start_y = bounds_height - CONTENT_TOP
      move_cursor_to(@content_start_y)
      current_cursor = cursor rescue nil
      available_height = current_cursor - CONTENT_BOTTOM
    end

    available_height = [available_height, 600].min

    begin
      bounds_height = bounds.height rescue 792
      top_y_position = bounds_height - current_cursor

      actual_height_used = height_of(text.to_s, width: content_width, size: font_size)
      actual_height_used = [actual_height_used, available_height].min

      y = y_from_top(top_y_position)

      bounding_box([CONTENT_LEFT, y], width: content_width, height: actual_height_used) do
        text_box(text.to_s,
                 at: [0, bounds.top],
                 width: content_width,
                 height: actual_height_used,
                 size: font_size,
                 style: style,
                 align: :left,
                 overflow: :shrink_to_fit,
                 valign: :top)
      end

      # Move cursor below the bounding box
      move_down(actual_height_used + spacing_after) rescue nil

    rescue => e
      # fallback simpler rendering
      begin
        lines = wrap_text(text.to_s, content_width, font_size)
        lines.each do |line|
          current_y = cursor rescue current_cursor
          if current_y - CONTENT_BOTTOM < font_size
            start_new_page
            bounds_height = bounds.height rescue 792
            move_cursor_to(bounds_height - CONTENT_TOP)
          end
          draw_text(line, at: [CONTENT_LEFT, cursor], size: font_size)
          move_down(font_size * 1.2) rescue nil
        end
        move_down(spacing_after) rescue nil
      rescue => e2
        Rails.logger.warn "add_paragraph failed: #{e2.message}" if defined?(Rails.logger)
      end
    end
  end

  def wrap_text(txt, max_width, font_size)
    return [""] if txt.nil?
    words = txt.split(/\s+/)
    lines = []
    current = ""
    words.each do |w|
      candidate = current.empty? ? w : "#{current} #{w}"
      if width_of(candidate) <= max_width
        current = candidate
      else
        lines << current
        current = w
      end
    end
    lines << current unless current.to_s.strip.empty?
    lines.any? ? lines : [txt]
  rescue => e
    [txt]
  end

  # ============================================
  # IMAGE COMPONENTS
  # ============================================
  def safe_add_image(path_or_url, is_header: false)
    return if path_or_url.nil? || @skip_images

    path = path_or_url.to_s
    image_path =
      if File.exist?(path)
        path
      elsif File.exist?(Rails.root.join("storage", "images", path).to_s)
        Rails.root.join("storage", "images", path).to_s
      elsif File.exist?(Rails.root.join("public", path).to_s)
        Rails.root.join("public", path).to_s
      else
        Rails.logger.warn "Image path not found: #{path}" if defined?(Rails.logger)
        nil
      end

    return unless image_path && File.exist?(image_path)

    ext = File.extname(image_path).to_s.downcase
    allowed = [".jpg", ".jpeg", ".png", ".gif"]
    return unless allowed.include?(ext)

    if is_header
      add_header_image(image_path)
    else
      add_content_image(image_path)
    end
  end

  def add_header_image(image_path)
    # Header image should be placed after header info, before main content
    safe_ensure_page
    begin
      # Position after header (around y=180)
      header_y = y_from_top(190)
      # Header images typically smaller
      max_w = bounds.width - CONTENT_LEFT - CONTENT_RIGHT
      image(image_path, at: [CONTENT_LEFT, header_y], width: max_w, fit: [max_w, 150])
      move_down(12) rescue nil
    rescue => e
      Rails.logger.warn "Failed to add header image: #{e.message}" if defined?(Rails.logger)
    end
  end

  def add_content_image(image_path)
    return unless image_path.present?
    safe_ensure_page

    begin
      test_bounds = bounds
      return unless test_bounds && test_bounds.respond_to?(:width)
      
      # Calculate content width
      max_w = test_bounds.width - CONTENT_LEFT - CONTENT_RIGHT
      
      # Get current cursor position
      current_y = cursor rescue nil
      return unless current_y

      # Add spacing before image
      move_down(IMAGE_SPACING_BEFORE) rescue nil
      image_start_y = cursor rescue (current_y - IMAGE_SPACING_BEFORE)

      # Calculate available height
      available_h = image_start_y - CONTENT_BOTTOM - 20

      # Check if we need a new page for image
      if available_h < 100
        start_new_page
        bounds_height = bounds.height rescue 792
        @content_start_y = bounds_height - CONTENT_TOP
        move_cursor_to(@content_start_y)
        image_start_y = cursor rescue @content_start_y
        available_h = image_start_y - CONTENT_BOTTOM - 20
      end

      # Get actual image dimensions using MiniMagick (if available)
      image_dimensions = get_image_dimensions(image_path)
      
      # Calculate available height for image
      max_display_h = [available_h, MAX_IMAGE_HEIGHT].min
      
      if image_dimensions
        # We have dimensions - use precise sizing
        img_width, img_height = image_dimensions
        aspect_ratio = img_width.to_f / img_height.to_f
        
        # Calculate display dimensions respecting max constraints
        if max_w / aspect_ratio <= max_display_h
          # Width-constrained: fit to max_w
          display_width = max_w
          display_height = max_w / aspect_ratio
        else
          # Height-constrained: fit to available height
          display_height = max_display_h
          display_width = max_display_h * aspect_ratio
        end
        
        # Calculate bottom-left Y position for image (Prawn uses bottom-left origin)
        image_bottom_y = image_start_y - display_height
        
        # Ensure image doesn't go below bottom margin
        if image_bottom_y < CONTENT_BOTTOM
          image_bottom_y = CONTENT_BOTTOM + 10
          # Recalculate with new constraint
          max_display_h = image_start_y - image_bottom_y
          if max_display_h > 0
            if max_display_h * aspect_ratio <= max_w
              display_height = max_display_h
              display_width = max_display_h * aspect_ratio
            else
              display_width = max_w
              display_height = max_w / aspect_ratio
              image_bottom_y = image_start_y - display_height
            end
          end
        end
        
        # Place image with calculated dimensions
        begin
          image(image_path, 
                at: [CONTENT_LEFT, image_bottom_y], 
                width: display_width, 
                height: display_height)
          
          # Update cursor position after image
          new_cursor_y = image_bottom_y - IMAGE_SPACING_AFTER
          if new_cursor_y < CONTENT_BOTTOM
            new_cursor_y = CONTENT_BOTTOM + 10
          end
          move_cursor_to(new_cursor_y)
        rescue Prawn::Errors::UnsupportedImageType
          # If explicit dimensions fail, try with fit
          image(image_path, at: [CONTENT_LEFT, image_start_y - max_display_h], fit: [max_w, max_display_h])
          move_cursor_to(image_start_y - max_display_h - IMAGE_SPACING_AFTER)
        end
      else
        # Fallback: use fit parameter - Prawn handles aspect ratio automatically
        # This works without ImageMagick
        fit_height = max_display_h
        
        begin
          # Use fit which maintains aspect ratio automatically
          image(image_path, 
                at: [CONTENT_LEFT, image_start_y - fit_height], 
                fit: [max_w, fit_height])
          
          # Estimate cursor position based on typical aspect ratio (1.33 = 4:3)
          # Most images are roughly this ratio
          estimated_display_height = [max_w / 1.33, fit_height].min
          new_cursor_y = image_start_y - estimated_display_height - IMAGE_SPACING_AFTER
          
          if new_cursor_y < CONTENT_BOTTOM
            new_cursor_y = CONTENT_BOTTOM + 10
          end
          move_cursor_to(new_cursor_y)
        rescue Prawn::Errors::UnsupportedImageType => e
          Rails.logger.warn "Prawn cannot process image: #{image_path} - #{e.message}" if defined?(Rails.logger)
        end
      end
      
    rescue Prawn::Errors::UnsupportedImageType => e
      Rails.logger.warn "Unsupported image, skipping: #{image_path} (#{e.message})" if defined?(Rails.logger)
    rescue => e
      Rails.logger.error "Failed to place image #{image_path}: #{e.class}: #{e.message}" if defined?(Rails.logger)
    end
  end

  def get_image_dimensions(image_path)
    return nil unless MINI_MAGICK_AVAILABLE
    
    # Track if we've already logged that ImageMagick is missing
    @imagemagick_missing_logged ||= false
    
    begin
      # Check if ImageMagick is actually available (not just the gem)
      img = MiniMagick::Image.open(image_path)
      [img.width, img.height]
    rescue MiniMagick::Error => e
      # ImageMagick not installed or identify command not found
      # Only log once to avoid spam
      unless @imagemagick_missing_logged
        Rails.logger.info "ImageMagick not available - using estimated image sizing" if defined?(Rails.logger)
        @imagemagick_missing_logged = true
      end
      nil
    rescue => e
      # Only log unexpected errors, not the expected "identify not found" errors
      unless e.message.include?("identify") && e.message.include?("executable not found")
        Rails.logger.warn "Could not get image dimensions for #{image_path}: #{e.message}" if defined?(Rails.logger)
      end
      nil
    end
  end

  # ============================================
  # PAGINATION COMPONENTS
  # ============================================
  def start_new_page_if_needed(min_height_needed)
    safe_ensure_page
    begin
      current_cursor = cursor rescue nil
      return unless current_cursor

      if (current_cursor - CONTENT_BOTTOM) < min_height_needed
        start_new_page
        bounds_height = bounds.height rescue 792
        @content_start_y = bounds_height - CONTENT_TOP
        move_cursor_to(@content_start_y)
      end
    rescue => e
      Rails.logger.warn "start_new_page_if_needed: cannot check cursor: #{e.message}" if defined?(Rails.logger)
      begin
        start_new_page
        bounds_height = bounds.height rescue 792
        @content_start_y = bounds_height - CONTENT_TOP
        move_cursor_to(@content_start_y)
      rescue => _
      end
    end
  end

  def safe_add_page_numbers
    begin
      number_pages "Page <page> of <total>", at: [bounds.left + (safe_bounds_width / 2), 30], align: :center, size: 9
    rescue => e
      Rails.logger.warn "safe_add_page_numbers skipped: #{e.message}" if defined?(Rails.logger)
    end
  end

  # ============================================
  # UTILITY METHODS
  # ============================================
  def move_cursor_to(y_position)
    # Helper to move cursor to absolute Y position (keeping X at CONTENT_LEFT)
    begin
      move_to([CONTENT_LEFT, y_position])
    rescue => e
      # Fallback: calculate relative movement
      begin
        current = cursor
        move_amount = current - y_position
        if move_amount > 0
          move_down(move_amount)
        elsif move_amount < 0
          move_up(-move_amount)
        end
      rescue => e2
        Rails.logger.warn "move_cursor_to failed: #{e2.message}" if defined?(Rails.logger)
      end
    end
  end

  def y_from_top(top_y)
    # Convert top-based Y coordinate to Prawn's bottom-left coordinate
    bounds.top - top_y rescue (792 - top_y)
  end

  def format_date(value)
    return "" if value.nil? || value.to_s.strip.empty?
    if value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/^\d+$/))
      ts = value.to_i
      ts = ts / 1000 if ts > 10**10
      Time.at(ts).to_date.strftime("%B %d, %Y") rescue value.to_s
    else
      Date.parse(value.to_s).strftime("%B %d, %Y") rescue value.to_s
    end
  end

  def decode_html_entities(text)
    return "" if text.nil?
    text.to_s.gsub("&apos;", "'")
             .gsub("&quot;", '"')
             .gsub("&amp;", "&")
             .gsub("&lt;", "<")
             .gsub("&gt;", ">")
             .gsub("&#39;", "'")
  end

  def safe_bounds_width
    bounds.width - CONTENT_LEFT - CONTENT_RIGHT rescue (Prawn::Document::PageGeometry::SIZES["A4"][0] - CONTENT_LEFT - CONTENT_RIGHT) rescue 500
  end

  def download_image_to_tmp(url)
    tmp_dir = Rails.root.join("tmp", "pdf_images")
    FileUtils.mkdir_p(tmp_dir) unless Dir.exist?(tmp_dir)
    ext = File.extname(URI.parse(url).path) rescue ".jpg"
    ext = ".jpg" if ext.blank?
    file = tmp_dir.join("#{Digest::MD5.hexdigest(url)}#{ext}").to_s
    return file if File.exist?(file)

    begin
      URI.open(url, "rb", read_timeout: 15, open_timeout: 10) do |remote|
        File.open(file, "wb") { |f| f.write(remote.read) }
      end
      file
    rescue => e
      Rails.logger.error "Failed to download image to tmp: #{e.message}" if defined?(Rails.logger)
      nil
    end
  end
end
