class ReportsController < ApplicationController
  def index
    # Read data from request body
    request_body = request.body.read
    params_data = {}
    
    if request_body.present?
      begin
        params_data = JSON.parse(request_body)
      rescue JSON::ParserError => e
        render json: { error: "Invalid JSON in request body", details: e.message }, status: :bad_request
        return
      end
    end

    # Process the reports based on the request body data
    # You can customize this logic based on your needs
    reports = generate_reports(params_data)

    render json: { reports: reports, received_params: params_data }, status: :ok
  end

  private

  def generate_reports(params)
    pdf = TemplatePdf.new(params)
    pdf.render_file(file_path)
    {
      message: "Reports generated successfully",
      params_received: params,
      timestamp: Time.current.iso8601
    }
  end

  def file_path
    "#{Rails.root}/output/#{file_name}"
  end

  def file_name
    "TREC_Template_#{Time.current.strftime("%Y%m%d%H%M%S")}.pdf"
  end
end

