# app/controllers/reports_controller.rb
require 'json'
require 'fileutils'
require 'uri'
require 'open-uri'
require 'digest'

class ReportsController < ApplicationController
  def index
    params_data = load_inspection_data_from_request_or_file

    if params_data.blank?
      render json: { error: "No inspection data found" }, status: :bad_request
      return
    end

    result = generate_reports(params_data)

    if result[:success]
      render json: {
        message: "Reports generated successfully",
        file_path: result[:file_path],
        timestamp: Time.current.iso8601
      }, status: :ok
    else
      render json: { error: result[:message] || "Failed to generate PDF" }, status: :internal_server_error
    end
  end

  private

  def load_inspection_data_from_request_or_file
    request_body = request.body.read
    if request_body.present?
      begin
        JSON.parse(request_body)
      rescue JSON::ParserError
        read_inspection_json
      end
    else
      read_inspection_json
    end
  end

  def read_inspection_json
    path = Rails.root.join("output", "inspection.json")
    return {} unless File.exist?(path)
    begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse inspection.json: #{e.message}" if defined?(Rails.logger)
      {}
    end
  end

  def generate_reports(params_hash)
    output_dir = Rails.root.join("output")
    FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

    begin
      # Accept either full hash or nested under "inspection"
      normalized = if params_hash.is_a?(Hash) && params_hash.key?("inspection")
                     params_hash["inspection"]
                   else
                     params_hash
                   end

      # Download and replace remote image URLs with local paths
      inspection_with_local_images = download_and_replace_images(normalized)

      # instantiate PDF (set skip_images: true to disable image placement for debugging)
      pdf = ::TemplatePdf.new(inspection_with_local_images, skip_images: false)

      output_file = output_dir.join("output_pdf.pdf").to_s
      pdf.render_file(output_file)

      { success: true, file_path: output_file }
    rescue => e
      Rails.logger.error "PDF generation failed: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}" if defined?(Rails.logger)
      { success: false, message: "#{e.class}: #{e.message}" }
    end
  end

  # Walks the inspection hash and downloads any http(s) image links to storage/images,
  # replacing them with local absolute paths.
  def download_and_replace_images(inspection_data)
    return inspection_data unless inspection_data.is_a?(Hash)

    images_dir = Rails.root.join("storage", "images")
    FileUtils.mkdir_p(images_dir) unless Dir.exist?(images_dir)

    # deep-clone so we don't mutate caller's object unexpectedly
    data = Marshal.load(Marshal.dump(inspection_data))

    if data["headerImageUrl"].present? && data["headerImageUrl"].to_s.start_with?("http")
      local = download_image_to_storage(data["headerImageUrl"], images_dir)
      data["headerImageUrl"] = local if local
    end

    if data["sections"].is_a?(Array)
      data["sections"].each do |section|
        next unless section.is_a?(Hash) && section["lineItems"].is_a?(Array)
        section["lineItems"].each do |li|
          next unless li.is_a?(Hash) && li["comments"].is_a?(Array)
          li["comments"].each do |comment|
            next unless comment.is_a?(Hash)
            if comment["photos"].is_a?(Array)
              comment["photos"] = comment["photos"].map do |photo|
                if photo.is_a?(String)
                  url = photo
                  if url.to_s.start_with?("http")
                    local = download_image_to_storage(url, images_dir)
                    local || photo
                  else
                    photo
                  end
                elsif photo.is_a?(Hash)
                  url = photo["url"] || photo[:url]
                  if url.to_s.start_with?("http")
                    local = download_image_to_storage(url, images_dir)
                    photo.merge("url" => (local || url))
                  else
                    photo
                  end
                else
                  photo
                end
              end
            end
          end
        end
      end
    end

    data
  end

  def download_image_to_storage(url, images_dir)
    return nil unless url.present? && url.to_s.start_with?("http")

    begin
      url_hash = Digest::MD5.hexdigest(url)
      uri = URI.parse(url)
      ext = File.extname(uri.path).presence || ".jpg"
      ext = ".jpg" if ext.empty?
      filename = "#{url_hash}#{ext}"
      filepath = images_dir.join(filename).to_s

      # skip if already present
      return filepath if File.exist?(filepath)

      URI.open(url, "rb", read_timeout: 30, open_timeout: 15) do |remote|
        File.open(filepath, "wb") { |f| f.write(remote.read) }
      end

      Rails.logger.info "Downloaded image: #{url} -> #{filepath}" if defined?(Rails.logger)
      filepath
    rescue => e
      Rails.logger.error "Failed to download image #{url}: #{e.message}" if defined?(Rails.logger)
      nil
    end
  end
end
