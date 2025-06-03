# app/controllers/calculator_controller.rb
require 'httparty'
require 'cgi'

class CalculatorController < ApplicationController
  JAX_API_BASE_URL = "https://ontology.jax.org/api/network"

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
        m = get_alleles_X_linked(mother_zygosity, false)

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
        selected_omim_id: nil,
        omim_main_disease_name: nil,
        inheritance_type: nil,
        all_related_omim_phenotypes: [], 
        error_message: nil
      }
      puts "PROCESSING GENE: #{gene_name}" # Sudah Inggris

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

        # 1b & 1c. Get Gene Annotations & Find first OMIM ID
        gene_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:jax_gene_id])}"
        puts "  1b. Gene Annotation URL: #{gene_annotation_url}" # Sudah Inggris
        gene_annotation_response = HTTParty.get(gene_annotation_url, timeout: 15)

        unless gene_annotation_response.success? && (parsed_gene_annotation = gene_annotation_response.parsed_response).is_a?(Hash) &&
              parsed_gene_annotation['diseases'].is_a?(Array)
          api_data_for_gene[:error_message] = "'diseases' annotation format from JAX Gene ID is invalid for '#{api_data_for_gene[:jax_gene_id]}'. (Status: #{gene_annotation_response.code rescue 'N/A'})"
          puts "  ERROR 1b/1c: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        
        omim_disease_entry = parsed_gene_annotation['diseases'].find { |disease| disease.is_a?(Hash) && disease['id']&.start_with?("OMIM:") }
        unless omim_disease_entry && omim_disease_entry['id'].present?
          api_data_for_gene[:error_message] = "OMIM ID not found in 'diseases' for gene annotation '#{api_data_for_gene[:jax_gene_id]}'."
          puts "  ERROR 1c: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        api_data_for_gene[:selected_omim_id] = omim_disease_entry['id']
        puts "  1c. Selected OMIM ID: #{api_data_for_gene[:selected_omim_id]}"

        # 1d. Get OMIM Annotations
        omim_details_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:selected_omim_id])}"
        puts "  1d. OMIM Annotation URL: #{omim_details_url}" # Sudah Inggris
        omim_details_response = HTTParty.get(omim_details_url, timeout: 15)

        unless omim_details_response.success? && (parsed_omim_details = omim_details_response.parsed_response).is_a?(Hash)
          api_data_for_gene[:error_message] = "Failed to retrieve details for OMIM ID '#{api_data_for_gene[:selected_omim_id]}'. (Status: #{omim_details_response.code rescue 'N/A'})"
          puts "  ERROR 1d: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        
        if parsed_omim_details['disease'].is_a?(Hash) && parsed_omim_details['disease']['name'].present?
          api_data_for_gene[:omim_main_disease_name] = parsed_omim_details['disease']['name']
          puts "  1d. OMIM Main Disease: #{api_data_for_gene[:omim_main_disease_name]}"
        else
          puts "  1d. No main 'disease' object or disease name in OMIM details."
        end
        
        if parsed_omim_details['categories'].is_a?(Hash) &&
          parsed_omim_details['categories']['Inheritance'].is_a?(Array) &&
          (first_inheritance_info = parsed_omim_details['categories']['Inheritance'].first).is_a?(Hash) &&
          first_inheritance_info['name'].present?
          api_data_for_gene[:inheritance_type] = first_inheritance_info['name']
          puts "  -> Inheritance Info Found: #{api_data_for_gene[:inheritance_type]}"
        else
          puts "  -> No valid 'Inheritance' info found in categories."
        end

        # STEP 1e: Perform phenotype matching
        # ====================================
        matched_this_gene_phenotypes = [] # For phenotypes matching this current gene

        # 1. Match with OMIM main disease name
        if api_data_for_gene[:omim_main_disease_name].present?
          main_disease_name = api_data_for_gene[:omim_main_disease_name]
          if searched_phenotypes.any? { |user_pheno| main_disease_name.downcase.include?(user_pheno.downcase.strip) || user_pheno.downcase.strip.include?(main_disease_name.downcase) }
            matched_this_gene_phenotypes << {
              name: main_disease_name,
              id: api_data_for_gene[:selected_omim_id],
              source: "OMIM Main Disease"
            }
            puts "  1e. MATCH (Main Disease): #{main_disease_name}"
          end
        end

        # 2. Match with all phenotypes within 'categories'
        if parsed_omim_details['categories'].is_a?(Hash)
          parsed_omim_details['categories'].each do |_category_name, phenotypes_in_category|
            next unless phenotypes_in_category.is_a?(Array)
            phenotypes_in_category.each do |pheno_detail|
              next unless pheno_detail.is_a?(Hash)
              pheno_name_from_category = pheno_detail['name']
              next if pheno_name_from_category.blank?

              is_already_matched = matched_this_gene_phenotypes.any? { |m| m[:id] == pheno_detail['id'] && m[:name] == pheno_name_from_category }

              if !is_already_matched && searched_phenotypes.any? { |user_pheno| pheno_name_from_category.downcase.include?(user_pheno.downcase.strip) || user_pheno.downcase.strip.include?(pheno_name_from_category.downcase) }
                matched_this_gene_phenotypes << {
                  id: pheno_detail['id'],
                  name: pheno_name_from_category,
                  category: pheno_detail['category'],
                  source: "OMIM Category Phenotype"
                }
                puts "  1e. MATCH (Category): #{pheno_name_from_category}"
              end
            end
          end
        end
        
        # ONLY ADD TO TEMP_RESULTS IF THERE ARE MATCHING PHENOTYPES
        if matched_this_gene_phenotypes.any?          
          # Assuming calculate_genotype expects 6 arguments: 
          # (gene_name, disease_name, inheritance_type, matched_phenotypes_list, father_zygosity, mother_zygosity)
          # If your calculate_genotype definition has changed to 5 arguments (excluding matched_phenotypes_list), 
          # then remove `matched_this_gene_phenotypes` from the call below.
          # def calculate_genotype(gene_name, diesease_name, inheritance_type, father_zygosity, mother_zygosity)
          calculation_result = calculate_genotype(
            api_data_for_gene[:gene_name],
            api_data_for_gene[:omim_main_disease_name],
            api_data_for_gene[:inheritance_type],
            zygosities_p1[index],
            zygosities_p2[index]
          )
          temp_results << {
            input_gene_name: api_data_for_gene[:gene_name],
            associated_disease_name: api_data_for_gene[:omim_main_disease_name],
            inheritance_type: api_data_for_gene[:inheritance_type],
            matched_phenotypes_details: matched_this_gene_phenotypes,
            calculation_result: calculation_result,
            error: nil # No error if it reached here and matched
          }
          puts "  -> GENE '#{gene_name}' HAS MATCHING PHENOTYPES, ADDED TO RESULTS."
        else
          puts "  -> GENE '#{gene_name}' HAS NO MATCHING PHENOTYPES, NOT ADDED TO RESULTS."
          # Optionally, add an entry to temp_results if you want to show genes that were processed but had no matches
          # temp_results << {
          #   input_gene_name: api_data_for_gene[:gene_name],
          #   associated_disease_name: api_data_for_gene[:omim_main_disease_name],
          #   inheritance_type: api_data_for_gene[:inheritance_type],
          #   error: "No phenotypes matched user input for this gene."
          # }
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
    calculator_data = params[:calculator]
    submitted_phenotypes = [] # Fenotip yang diinput pengguna
    phenotypes_p1 = []
    phenotypes_p2 = []
    temp_result = []

    if calculator_data.present?
      # isi variabel di sini
      submitted_phenotypes = calculator_data[:phenotypes]&.reject(&:blank?) || []
      phenotypes_p1 = calculator_data[:phenotypes_p1]&.reject(&:blank?) || []
      phenotypes_p2 = calculator_data[:phenotypes_p2]&.reject(&:blank?) || []
    else
      flash[:alert] = "Tidak ada data input yang diterima."
      redirect_to phenotype_calculator_path
      return
    end

    # cara ngasih ke fe, misalnya jadiin list json
    submitted_phenotypes.each_with_index do |phenotype, index|
      temp_result << {phenotype: phenotype, p1: phenotypes_p1[index], p2: phenotypes_p2[index]}
    end
    flash[:kalkulasi_results_data] = temp_result

    redirect_to phenotype_calculator_path
  end
end