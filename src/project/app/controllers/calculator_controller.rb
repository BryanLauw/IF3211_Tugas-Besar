# app/controllers/calculator_controller.rb
require 'httparty'
require 'cgi'

class CalculatorController < ApplicationController
  JAX_API_BASE_URL = "https://ontology.jax.org/api/network"
  API_TIMEOUT = 15

  def genotype
    @form_params = session.delete(:last_calculator_input) || {}
    @processed_results = session.delete(:kalkulasi_results_data) || []
  end

  def get_alleles(zygosity)
    case zygosity
    when "Homozygot Dominant"
      ["A", "A"]
    when "Heterozygot"
      ["A", "a"]
    else
      ["a", "a"]
    end
  end

  def get_alleles_X_linked(zygosity, male)
    if male
      if zygosity == "Heterozygot"
        return ["XA", "Y"]
      else
        return ["Xa", "Y"]
      end
    else
      if zygosity == "Homozygot Dominant"
        return ["XA", "XA"]
      elsif zygosity == "Heterozygot"
        return ["XA", "Xa"]
      else
        return ["Xa", "Xa"]
      end
    end
  end

  def calculate_genotype(gene_name, diesease_name, inheritance_type, father_zygosity, mother_zygosity)
    retVal = {
      kids: nil,
      boys: nil,
      girls: {
        percentage: nil,
        carrier: nil
      },
      fault: nil
    }

    case inheritance_type

    when "Autosomal dominant inheritance"
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f = get_alleles(father_zygosity)
        m = get_alleles(mother_zygosity)

        combinations = f.product(m).map { |a1, a2| [a1, a2].join }
        affected = combinations.count { |geno| geno.include?("A") }

        retVal[:kids] = ((affected.to_f / combinations.size) * 100).round(2)
      end

    when "Autosomal recessive inheritance"
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f = get_alleles(father_zygosity)
        m = get_alleles(mother_zygosity)

        combinations = f.product(m).map { |a1, a2| [a1, a2].join }
        affected = combinations.count { |geno| geno == "aa" }

        retVal[:kids] = ((affected.to_f / combinations.size) * 100).round(2)
      end

    when "X-linked dominant inheritance"
      if father_zygosity == "Homozygot Dominant"
        retVal[:fault] = "Error: father must be Heterozygot or Homozygot Recessive in X-linked inheritance."
      else
        f = get_alleles_X_linked(father_zygosity, true)
        m = get_alleles_X_linked(mother_zygosity, false)

        combinations = f.product(m).map { |a1, a2| [a1, a2].join }

        affected_boys = combinations.count { |geno| geno == "YXA" }
        boys_count = combinations.count { |geno| geno.include?("Y") }

        affected_girls = combinations.count do |geno|
          !geno.include?("Y") && geno.include?("XA")
        end
        girls_count = combinations.count { |geno| !geno.include?("Y") }

        retVal[:boys] = ((affected_boys.to_f / boys_count) * 100).round(2)
        
        retVal[:girls] = {
          percentage: ((affected_girls.to_f / girls_count) * 100).round(2),
          carrier: nil
        }
      end

    when "X-linked recessive inheritance"
      if father_zygosity == "Homozygot Dominant"
        retVal[:fault] = "Error: father must be Heterozygot or Homozygot Recessive in X-linked inheritance."
      else
        f = father_zygosity == "None" ? ["XA", "Y"] : get_alleles_X_linked(father_zygosity, true)
        m = mother_zygosity == "None" ? ["XA", "XA"] : get_alleles_X_linked(mother_zygosity, false)

        combinations = f.product(m).map { |a1, a2| [a1, a2].join }

        affected_boys = combinations.count { |geno| geno == "YXa" }
        boys_count = combinations.count { |geno| geno.include?("Y") }

        affected_girls = combinations.count { |geno| geno == "XaXa" }
        carrier_girls = combinations.count do |geno|
          ["XAXa", "XaXA"].include?(geno)
        end
        girls_count = combinations.count { |geno| !geno.include?("Y") }

        retVal[:boys] = ((affected_boys.to_f / boys_count) * 100).round(2)
        
        retVal[:girls] = {
          percentage: ((affected_girls.to_f / girls_count) * 100).round(2),
          carrier: ((carrier_girls.to_f / girls_count) * 100).round(2)
        }
      end

    when "Y-linked inheritance"
      if mother_zygosity != "None"
        retVal[:fault] = "Error: Y-linked inheritance cannot involve maternal zygosity. Only males inherit the Y chromosome from their father."
      elsif father_zygosity != "Heterozygot"
        retVal[:fault] = "Error: father must be Heterozygot in Y-linked inheritance."
      else
        retVal[:boys] = 100.00
      end

    when "Mitochondrial inheritance"
      if mother_zygosity == "None"
        retVal[:fault] = "Error: Mitochondrial inheritance only involve maternal zygosity."
      elsif father_zygosity != "None"
        retVal[:fault] = "Error: Father's zygosity for Mitochondrial inheritance must be None."
      else
        retVal[:kids] = 100.00
      end

    else # Anggap Autosomal dominant inheritance
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f = get_alleles(father_zygosity)
        m = get_alleles(mother_zygosity)

        combinations = f.product(m).map { |a1, a2| [a1, a2].join }
        affected = combinations.count { |geno| geno.include?("A") }

        retVal[:kids] = ((affected.to_f / combinations.size) * 100).round(2)
      end
    end

    return retVal
  end

  def process_genotype
    calculator_data = params[:calculator]
    submitted_genes = []
    searched_phenotypes = [] # User-searched phenotypes
    zygosities_p1 = []
    zygosities_p2 = []

    if calculator_data.present?
      permitted_input_params = calculator_data.permit(genes: [], zygosities_p1: [], zygosities_p2: [], phenotypes: [])
      session[:last_calculator_input] = permitted_input_params.to_h
      submitted_genes = calculator_data[:genes]&.reject(&:blank?) || []
      searched_phenotypes = calculator_data[:phenotypes]&.reject(&:blank?) || []
      zygosities_p1 = calculator_data[:zygosities_p1]&.reject(&:blank?) || []
      zygosities_p2 = calculator_data[:zygosities_p2]&.reject(&:blank?) || []
    else
      session[:alert] = "Input data not received." # Diubah dari "Input not found." untuk kejelasan
      redirect_to genotype_calculator_path
      return
    end

    temp_results = []

    # Initial validation: genes AND searched phenotypes are required if we only want to save matches
    if submitted_genes.empty?
      session[:alert] = "Gene inputs are required."
      redirect_to genotype_calculator_path
      return
    elsif searched_phenotypes.empty?
      session[:alert] = "Searched phenotype input is required to display results."
      redirect_to genotype_calculator_path
      return
    end

    # Validate zygosity array lengths (Important!)
    unless submitted_genes.length == zygosities_p1.length && submitted_genes.length == zygosities_p2.length
      session[:alert] = "Zygosity data is incomplete or does not match the number of genes submitted. Please check your input."
      redirect_to genotype_calculator_path
      return
    end

    submitted_genes.each_with_index do |gene_name, index|
      api_data_for_gene = {
        gene_name: gene_name,
        jax_gene_id: nil,
        # selected_omim_id, omim_main_disease_name, inheritance_type tidak lagi di level ini
        # karena bisa ada multiple matches
        error_message: nil
      }
      puts "PROCESSING GENE: #{gene_name}"

      begin
        # 1a. Search Gene
        gene_search_url = "#{JAX_API_BASE_URL}/search/gene?q=#{CGI.escape(gene_name)}&limit=1"
        puts "  1a. Gene Search URL: #{gene_search_url}" # Sudah Inggris
        gene_search_response = HTTParty.get(gene_search_url, timeout: 15)

        unless gene_search_response.success? && (parsed_gene_search = gene_search_response.parsed_response).is_a?(Hash) &&
              parsed_gene_search['results'].is_a?(Array) && !parsed_gene_search['results'].empty? &&
              (first_gene_result = parsed_gene_search['results'].first).is_a?(Hash) && first_gene_result['id'].present?
          api_data_for_gene[:error_message] = "Gene '#{gene_name}' not found or API search format is invalid. (Status: #{gene_search_response.code rescue 'N/A'})"
          puts "  ERROR 1a: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        api_data_for_gene[:jax_gene_id] = first_gene_result['id']
        puts "  1a. JAX Gene ID: #{api_data_for_gene[:jax_gene_id]}" # Sudah Inggris

        # 1b. Get Gene Annotations
        gene_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:jax_gene_id])}"
        puts "  1b. Gene Annotation URL: #{gene_annotation_url}"
        gene_annotation_response = HTTParty.get(gene_annotation_url, timeout: 15)

        unless gene_annotation_response.success? && (parsed_gene_annotation = gene_annotation_response.parsed_response).is_a?(Hash) &&
               parsed_gene_annotation['diseases'].is_a?(Array)
          api_data_for_gene[:error_message] = "'diseases' annotation format from JAX Gene ID is invalid for '#{api_data_for_gene[:jax_gene_id]}'. (Status: #{gene_annotation_response.code rescue 'N/A'})"
          puts "  ERROR 1b: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end

        # Flag untuk melacak apakah setidaknya satu kecocokan OMIM diproses untuk gen ini
        any_omim_match_processed_for_this_gene = false

        # Iterasi melalui SEMUA 'diseases' dari anotasi gen
        parsed_gene_annotation['diseases'].each do |disease_data_from_gene_annotation|
          next unless disease_data_from_gene_annotation.is_a?(Hash) &&
                      disease_data_from_gene_annotation['id']&.start_with?("OMIM:") &&
                      disease_data_from_gene_annotation['name'].present?

          current_omim_id_from_list = disease_data_from_gene_annotation['id']
          current_omim_name_from_list = disease_data_from_gene_annotation['name']

          # Lakukan pencocokan dengan setiap fenotipe yang dicari pengguna
          is_phenotype_match = searched_phenotypes.any? do |user_pheno|
            user_pheno_clean = user_pheno.downcase.strip
            current_omim_name_clean = current_omim_name_from_list.downcase
            current_omim_name_clean.include?(user_pheno_clean) || user_pheno_clean.include?(current_omim_name_clean)
          end

          if is_phenotype_match
            puts "  MATCH FOUND: Gene '#{gene_name}' linked to OMIM Disease '#{current_omim_name_from_list}' (ID: #{current_omim_id_from_list}) which matches user search."
            
            inheritance_type_for_this_match = nil # Default

            # Dapatkan detail OMIM (termasuk tipe pewarisan) untuk ID OMIM yang cocok ini
            omim_details_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(current_omim_id_from_list)}"
            puts "    Fetching details for matched OMIM ID: #{omim_details_url}"
            omim_details_response = HTTParty.get(omim_details_url, timeout: 15)

            if omim_details_response.success? && (parsed_omim_details_for_match = omim_details_response.parsed_response).is_a?(Hash)
              if parsed_omim_details_for_match['categories'].is_a?(Hash) &&
                 parsed_omim_details_for_match['categories']['Inheritance'].is_a?(Array) &&
                 (first_inheritance_info = parsed_omim_details_for_match['categories']['Inheritance'].first).is_a?(Hash) &&
                 first_inheritance_info['name'].present?
                inheritance_type_for_this_match = first_inheritance_info['name']
                puts "    -> Inheritance Info for '#{current_omim_name_from_list}': #{inheritance_type_for_this_match}"
              else
                puts "    -> No valid 'Inheritance' info found for OMIM ID '#{current_omim_id_from_list}'."
              end
            else
              puts "    ERROR: Failed to retrieve details for matched OMIM ID '#{current_omim_id_from_list}'. (Status: #{omim_details_response.code rescue 'N/A'})"
              # Anda bisa memutuskan apakah kegagalan mengambil detail ini harus menghentikan penambahan ke hasil
              # atau tetap menambahkannya dengan inheritance_type = nil
            end
            
            # Jika detail (meskipun inheritance_type bisa nil) berhasil diproses sampai tahap ini, set flag
            any_omim_match_processed_for_this_gene = true

            # Persiapkan detail fenotip yang cocok untuk fungsi calculate_genotype dan untuk disimpan
            matched_phenotype_detail_for_this_iteration = [{
              name: current_omim_name_from_list,
              id: current_omim_id_from_list,
              source: "OMIM Match from Gene Annotation" # Sumber lebih spesifik
            }]

            # Panggil fungsi calculate_genotype untuk SETIAP kecocokan OMIM
            # Definisi fungsi calculate_genotype Anda:
            # def calculate_genotype(gene_name, diesease_name, inheritance_type, father_zygosity, mother_zygosity)
            calculation_result = calculate_genotype(
              gene_name,
              current_omim_name_from_list,
              inheritance_type_for_this_match, # Bisa nil
              zygosities_p1[index],
              zygosities_p2[index]
            )

            temp_results << {
              input_gene_name: gene_name,
              associated_disease_name: current_omim_name_from_list,
              inheritance_type: inheritance_type_for_this_match,
              matched_phenotypes_details: matched_phenotype_detail_for_this_iteration, # Ini adalah detail untuk kecocokan spesifik ini
              calculation_result: calculation_result,
              error: nil # Error API gen sudah ditangani. Error detail OMIM bisa dicatat di log atau ditambahkan ke calculation_result jika perlu.
            }
            puts "  -> GENE '#{gene_name}' - Processed OMIM match: '#{current_omim_name_from_list}'."
            # TIDAK ADA 'break' di sini, jadi loop akan berlanjut ke disease_data berikutnya
          end # akhir dari if is_phenotype_match
        end # akhir dari iterasi parsed_gene_annotation['diseases']

        # Setelah loop 'diseases' selesai:
        # Jika tidak ada kecocokan OMIM sama sekali yang diproses untuk gen ini,
        # DAN tidak ada error API sebelumnya untuk gen ini (misalnya, gen tidak ditemukan).
        if !any_omim_match_processed_for_this_gene && api_data_for_gene[:error_message].nil?
          puts "  -> GENE '#{gene_name}' (JAX ID: #{api_data_for_gene[:jax_gene_id]}) - No OMIM diseases listed for this gene matched the user's searched phenotypes."
          temp_results << {
            input_gene_name: gene_name,
            error: "No OMIM diseases linked to this gene matched your searched phenotypes."
            # Anda bisa tambahkan field lain seperti jax_gene_id atau associated_disease_name: "N/A" jika mau ditampilkan di UI
          }
        end

      rescue HTTParty::Error, SocketError => e
        temp_results << { input_gene_name: gene_name, error: "API connection issue: #{e.message}" }
      rescue StandardError => e
        temp_results << { input_gene_name: gene_name, error: "Unexpected error: #{e.message}", backtrace: e.backtrace.first(5) }
        puts "STACKTRACE: #{e.backtrace.join("\n")}" # Log full stacktrace on server
      end
    end

    session[:kalkulasi_results_data] = temp_results # Storing results in session
    
    # Set flash messages based on processing outcome
    if !calculator_data.present? || (submitted_genes.empty? && searched_phenotypes.empty?)
      session[:alert] = "No valid input data to process."
    else
      successful_matches_count = temp_results.count { |r| r[:error].nil? && r[:matched_phenotypes_details].present? && r[:matched_phenotypes_details].any? }
      error_entries_count = temp_results.count { |r| r[:error].present? }
      total_submitted_genes = submitted_genes.count

      if successful_matches_count > 0
        session[:notice] = "Found #{successful_matches_count} gene(s) with matching phenotypes."
        if error_entries_count > 0
          session[:alert] = "However, #{error_entries_count} other gene(s) had issues during processing or were not found."
        end
      elsif error_entries_count == total_submitted_genes && total_submitted_genes > 0
        session[:alert] = "All #{total_submitted_genes} submitted gene(s) encountered issues during processing."
      elsif error_entries_count > 0 && error_entries_count < total_submitted_genes
        # This means some had errors, and the rest (that didn't error out early) didn't have matches.
        session[:alert] = "#{error_entries_count} gene(s) had processing issues. The remaining processed genes did not find matching phenotypes."
      elsif total_submitted_genes > 0 && temp_results.all? { |r| r[:error].present? || r[:matched_phenotypes_details].blank? || !r[:matched_phenotypes_details].any? }
        # All processed genes either had an error or no matching phenotypes.
        session[:info] = "No matching phenotypes were found for the processed genes, or all genes encountered errors."
      elsif temp_results.empty? && total_submitted_genes > 0 # All genes failed very early (e.g. API down) or no genes had any matches
          session[:info] = "No genes resulted in matching phenotypes, or processing could not be completed for any gene."
      elsif temp_results.empty? && total_submitted_genes == 0 && calculator_data.present?
        session[:alert] = "No valid genes were submitted for processing." # More specific
      else # Fallback, should be rare if other conditions are comprehensive
        session[:info] = "Processing complete. Check results."
      end
    end
    
    redirect_to genotype_calculator_path 
  end

  def phenotype
    @processed_results = flash[:kalkulasi_results_data] || []
  end

  def process_phenotype
    calculator_params = params[:calculator]

    unless calculator_params.present? &&
           calculator_params[:phenotypes].is_a?(Array) &&
           calculator_params[:phenotypes_p1].is_a?(Array) &&
           calculator_params[:phenotypes_p2].is_a?(Array)
      flash[:alert] = "Data input tidak lengkap atau format salah. Mohon coba lagi."
      redirect_to phenotype_calculator_path
      return
    end

    raw_phenotypes = calculator_params[:phenotypes]
    raw_phenotypes_p1 = calculator_params[:phenotypes_p1]
    raw_phenotypes_p2 = calculator_params[:phenotypes_p2]

    user_inputs = []
    raw_phenotypes.each_with_index do |pheno_name, idx|
      next if pheno_name.blank?
      user_inputs << {
        name: pheno_name,
        p1: raw_phenotypes_p1[idx],
        p2: raw_phenotypes_p2[idx]
      }
    end

    if user_inputs.empty?
      flash[:alert] = "Tidak ada nama fenotip valid yang diinput. Mohon isi setidaknya satu baris fenotip dengan lengkap."
      redirect_to phenotype_calculator_path
      return
    end

    processed_data_for_flash = []

    user_inputs.each do |input_item|
      current_result = {
        "phenotype" => input_item[:name],
        "p1" => input_item[:p1],
        "p2" => input_item[:p2],
        "input_phenotype_name" => input_item[:name],
        "input_parent1_phenotype" => input_item[:p1],
        "input_parent2_phenotype" => input_item[:p2],
        "api_omim_id" => nil,
        "api_disease_name" => nil,
        "api_inheritance_type" => nil,
        "api_gene_symbol" => nil,
        "api_error" => nil
      }

      begin
        disease_search_url = "#{JAX_API_BASE_URL}/search/disease?q=#{CGI.escape(input_item[:name])}&limit=-1"
        disease_search_response = HTTParty.get(disease_search_url, timeout: API_TIMEOUT)

        unless disease_search_response.success?
          current_result["api_error"] = "Gagal menghubungi API pencarian penyakit (Status: #{disease_search_response.code})."
          processed_data_for_flash << current_result
          next
        end

        parsed_disease_search = disease_search_response.parsed_response
        unless parsed_disease_search.is_a?(Hash) && parsed_disease_search['results'].is_a?(Array)
          current_result["api_error"] = "Format respons API pencarian penyakit tidak sesuai."
          processed_data_for_flash << current_result
          next
        end

        omim_entries = parsed_disease_search['results'].select do |r|
          r.is_a?(Hash) && r['id'].is_a?(String) && r['id'].start_with?("OMIM:")
        end

        selected_omim_entry = omim_entries.find do |r_omim|
          r_omim['name'].is_a?(String) && r_omim['name'].casecmp(input_item[:name]) == 0
        end

        selected_omim_entry ||= omim_entries.find { |r_omim| r_omim['name'].is_a?(String) }
        selected_omim_entry ||= omim_entries.first

        unless selected_omim_entry && selected_omim_entry['id'].is_a?(String)
          current_result["api_error"] = "Tidak ditemukan OMIM ID valid untuk fenotip '#{input_item[:name]}'."
          processed_data_for_flash << current_result
          next
        end
        
        omim_id_from_api = selected_omim_entry['id']
        name_from_api = selected_omim_entry['name']

        current_result["api_omim_id"] = omim_id_from_api
        current_result["api_disease_name"] = name_from_api.is_a?(String) ? name_from_api : nil


        omim_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(omim_id_from_api)}"
        omim_annotation_response = HTTParty.get(omim_annotation_url, timeout: API_TIMEOUT)

        unless omim_annotation_response.success?
          current_result["api_error"] = "Gagal mengambil anotasi untuk OMIM ID '#{omim_id_from_api}' (Status: #{omim_annotation_response.code})."
          processed_data_for_flash << current_result
          next
        end
        
        parsed_omim_annotation = omim_annotation_response.parsed_response
        unless parsed_omim_annotation.is_a?(Hash)
          current_result["api_error"] = "Format respons API anotasi OMIM tidak sesuai."
          processed_data_for_flash << current_result
          next
        end

        inheritance_info = parsed_omim_annotation.dig('categories', 'Inheritance', 0, 'name')
        if inheritance_info.is_a?(String) && inheritance_info.present?
          current_result["api_inheritance_type"] = inheritance_info
        else
          current_result["api_error"] = [current_result["api_error"], "Info pewarisan tidak ditemukan atau format tidak sesuai."].compact.join(" ").strip
        end

        current_result["api_error"] = nil if current_result["api_error"].blank?

      rescue HTTParty::Error, SocketError, Timeout::Error => e
        Rails.logger.error "JAX API Network Error for phenotype '#{input_item&.[](:name) || 'unknown'}': #{e.class} - #{e.message}"
        current_result["api_error"] = "Kesalahan jaringan atau timeout saat menghubungi JAX API: #{e.message}"
      rescue StandardError => e
        log_message = "Unexpected error processing phenotype "
        log_message += (input_item && input_item[:name]) ? "'#{input_item[:name]}'" : "[unknown phenotype input]"
        log_message += ": #{e.class} - #{e.message}"
        if e.backtrace.is_a?(Array)
          log_message += "\nBacktrace:\n#{e.backtrace.first(10).join("\n")}"
        end
        Rails.logger.error log_message
        
        current_result["api_error"] = "Terjadi kesalahan internal tidak terduga saat memproses fenotip. Silakan coba lagi."
      ensure
        processed_data_for_flash << current_result
      end
    end

    flash[:kalkulasi_results_data] = processed_data_for_flash
    redirect_to phenotype_calculator_path
  end
end