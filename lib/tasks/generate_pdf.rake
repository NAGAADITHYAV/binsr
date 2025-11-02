namespace :pdf do
  desc "Generate output_pdf.pdf from inspection.json"
  task :generate => :environment do
    json_path = Rails.root.join("output", "inspection.json")
    
    unless File.exist?(json_path)
      puts "Error: inspection.json not found at #{json_path}"
      exit 1
    end
    
    begin
      inspection_data = JSON.parse(File.read(json_path))
      
      # Ensure output directory exists
      output_dir = Rails.root.join("output")
      FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)
      
      # Generate the PDF (use root namespace)
      pdf = ::TemplatePdf.new(inspection_data)
      output_file_path = output_dir.join("output_pdf.pdf").to_s
      pdf.render_file(output_file_path)
      
      puts "✅ PDF generated successfully at: #{output_file_path}"
      puts "📄 File size: #{File.size(output_file_path) / 1024} KB"
    rescue => e
      puts "❌ Error generating PDF: #{e.message}"
      puts e.backtrace.first(5).join("\n")
      exit 1
    end
  end
end

