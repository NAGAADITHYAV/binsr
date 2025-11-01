require "prawn/templates"

class TemplatePdf < Prawn::Document
  def initialize(report)
    template_path = Rails.root.join("storage", "TREC_Template_Blank.pdf")
    
    # Load the template PDF as the base
    if File.exist?(template_path)
      super(template: template_path.to_s, page_size: "A4")
    else
      # Fallback to A4 if template doesn't exist
      super(page_size: "A4")
    end
    
    @report = report
    build_pdf
  end

  private

  def build_pdf
    # Add your PDF content here
    # The template PDF will be used as the background
    # You can add text, images, etc. on top of it
    
    # Example: add some text
    # text "Report Data: #{@report.inspect}", size: 12
  end
end