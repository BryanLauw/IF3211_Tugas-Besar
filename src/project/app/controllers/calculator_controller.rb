# app/controllers/calculator_controller.rb
require 'httparty'
require 'cgi'
require 'securerandom'

class CalculatorController < ApplicationController
  JAX_API_BASE_URL = "https://ontology.jax.org/api/network"
  API_TIMEOUT = 15

  def genotype
    @form_params = session.delete(:last_calculator_input) || {} # Untuk repopulasi form
    
    submission_batch_id = flash[:genotype_submission_batch_id]
    if submission_batch_id.present?
      # Ambil hasil dari database berdasarkan batch ID, urutkan sesuai keinginan
      @processed_results = GenotypeCalculationResult.where(submission_batch_id: submission_batch_id).order(created_at: :asc)
    else
      @processed_results = []
    end
    # Pesan flash[:alert], flash[:notice], flash[:info] akan otomatis tersedia di view
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

  def calculate_punnet(gene_name, disease_name, inheritance_type, father_zygosity, mother_zygosity)
    start_time = Time.now # Menambahkan ini untuk mulai mengukur waktu

    retVal = {
      kids: nil,
      boys: nil,
      girls: {
        percentage: nil,
        carrier: nil
      },
      fault: nil,
      processing_time_seconds: nil # Menambahkan key untuk waktu proses
    }

    case inheritance_type
    when "Autosomal dominant inheritance"
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f_alleles = get_alleles(father_zygosity)
        m_alleles = get_alleles(mother_zygosity)

        # Generate all possible genotype combinations
        # Example: f_alleles = ['A', 'a'], m_alleles = ['A', 'a']
        # Combinations: ["AA", "Aa", "aA", "aa"]
        combinations = f_alleles.product(m_alleles).map { |a1, a2| [a1, a2].sort.join('') } # Sort to normalize "aA" to "Aa"
        
        # For autosomal dominant, affected if any 'A' allele is present
        affected_count = combinations.count { |geno| geno.include?("A") }

        retVal[:kids] = ((affected_count.to_f / combinations.size) * 100).round(2)
      end

    when "Autosomal recessive inheritance"
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f_alleles = get_alleles(father_zygosity)
        m_alleles = get_alleles(mother_zygosity)

        combinations = f_alleles.product(m_alleles).map { |a1, a2| [a1, a2].sort.join('') } # Sort to normalize "aA" to "Aa"
        
        # For autosomal recessive, affected only if homozygous recessive ('aa')
        affected_count = combinations.count { |geno| geno == "aa" }

        retVal[:kids] = ((affected_count.to_f / combinations.size) * 100).round(2)
      end

    when "X-linked dominant inheritance"
      # Father cannot be Homozygot Dominant for X-linked (only one X chromosome)
      if father_zygosity == "Homozygot Dominant"
        retVal[:fault] = "Error: Father's zygosity for X-linked inheritance must be 'Unaffected' (XaY) or 'Affected' (XAY), not 'Homozygot Dominant'."
      elsif father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: Both parents' zygosity must be specified for X-linked inheritance."
      else
        f_alleles = get_alleles_X_linked(father_zygosity, true)  # ['XA', 'Y'] or ['Xa', 'Y']
        m_alleles = get_alleles_X_linked(mother_zygosity, false) # ['XA', 'XA'], ['XA', 'Xa'], or ['Xa', 'Xa']

        combinations = f_alleles.product(m_alleles).map { |a1, a2| [a1, a2].join('') }
        
        # Normalize X-linked combinations to canonical form (e.g., 'YXA' to 'XAY', 'XAXa' stays)
        normalized_combinations = combinations.map do |geno|
          if geno.include?('Y') # Boy: always X_Y
            x_allele = geno.gsub('Y', '') # Get XA or Xa
            x_allele + 'Y' # e.g., 'XAY' or 'XaY'
          else # Girl: always X_X_
            # Ensure XA is always before Xa for consistency if Heterozygous
            if geno.include?('XA') && geno.include?('Xa')
              'XAXa'
            else
              geno # e.g., 'XAXA' or 'XaXa'
            end
          end
        end

        boys_genotypes = normalized_combinations.select { |geno| geno.include?("Y") }
        girls_genotypes = normalized_combinations.select { |geno| !geno.include?("Y") }

        boys_count = boys_genotypes.size
        girls_count = girls_genotypes.size

        # For X-linked dominant:
        # Boys are affected if they get XA
        # Girls are affected if they get at least one XA (XAXA or XAXa)
        affected_boys = boys_genotypes.count { |geno| geno.include?("XA") }
        affected_girls = girls_genotypes.count { |geno| geno.include?("XA") }

        retVal[:boys] = (boys_count > 0 ? (affected_boys.to_f / boys_count) * 100 : 0.0).round(2)
        
        retVal[:girls] = {
          percentage: (girls_count > 0 ? (affected_girls.to_f / girls_count) * 100 : 0.0).round(2),
          carrier: nil # No 'carrier' concept for X-linked dominant affected status (a carrier would be affected)
        }
      end

    when "X-linked recessive inheritance"
      # Father cannot be Homozygot Dominant for X-linked (only one X chromosome)
      if father_zygosity == "Homozygot Dominant"
        retVal[:fault] = "Error: Father's zygosity for X-linked inheritance must be 'Unaffected' (XaY) or 'Affected' (XAY), not 'Homozygot Dominant'."
      elsif father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: Both parents' zygosity must be specified for X-linked inheritance."
      else
        f_alleles = get_alleles_X_linked(father_zygosity, true)
        m_alleles = get_alleles_X_linked(mother_zygosity, false)

        combinations = f_alleles.product(m_alleles).map { |a1, a2| [a1, a2].join('') }
        
        # Normalize combinations
        normalized_combinations = combinations.map do |geno|
          if geno.include?('Y')
            x_allele = geno.gsub('Y', '')
            x_allele + 'Y'
          else
            if geno.include?('XA') && geno.include?('Xa')
              'XAXa'
            else
              geno
            end
          end
        end

        boys_genotypes = normalized_combinations.select { |geno| geno.include?("Y") }
        girls_genotypes = normalized_combinations.select { |geno| !geno.include?("Y") }

        boys_count = boys_genotypes.size
        girls_count = girls_genotypes.size

        # For X-linked recessive:
        # Boys are affected if they get Xa (XaY)
        # Girls are affected only if homozygous recessive (XaXa)
        # Girls are carriers if heterozygous (XAXa)
        affected_boys = boys_genotypes.count { |geno| geno == "XaY" }
        affected_girls = girls_genotypes.count { |geno| geno == "XaXa" }
        carrier_girls = girls_genotypes.count { |geno| geno == "XAXa" }

        retVal[:boys] = (boys_count > 0 ? (affected_boys.to_f / boys_count) * 100 : 0.0).round(2)
        
        retVal[:girls] = {
          percentage: (girls_count > 0 ? (affected_girls.to_f / girls_count) * 100 : 0.0).round(2),
          carrier: (girls_count > 0 ? (carrier_girls.to_f / girls_count) * 100 : 0.0).round(2)
        }
      end

    when "Y-linked inheritance"
      # Y-linked traits are only passed from father to son.
      if mother_zygosity != "None"
        retVal[:fault] = "Error: Y-linked inheritance cannot involve maternal zygosity. Only males inherit the Y chromosome from their father."
      # The original code checked for "Heterozygot" for father. For Y-linked, a father is either "Affected" or "Unaffected".
      # I'm interpreting "Heterozygot" here as "Affected" based on context, but "Affected" is more direct.
      # If the intent was for a father who is "Unaffected" for the Y-linked trait, it should be handled differently.
      elsif father_zygosity != "Affected"
        retVal[:fault] = "Error: Father's zygosity for Y-linked inheritance must be 'Affected' to pass the trait."
      else
        # If father is affected, all sons will be affected. Daughters are never affected.
        retVal[:boys] = 100.00
        retVal[:girls][:percentage] = 0.00 # Daughters are never affected by Y-linked traits
        retVal[:girls][:carrier] = nil # No carrier concept for Y-linked
      end

    when "Mitochondrial inheritance"
      # Mitochondrial traits are only passed from mother to all children.
      if father_zygosity != "None"
        retVal[:fault] = "Error: Father's zygosity for Mitochondrial inheritance must be 'None'."
      elsif mother_zygosity == "None"
        retVal[:fault] = "Error: Mother's zygosity must be specified for Mitochondrial inheritance."
      elsif mother_zygosity == "Unaffected"
        retVal[:kids] = 0.00 # If mother is unaffected, no children will be affected.
      elsif mother_zygosity == "Affected"
        retVal[:kids] = 100.00 # If mother is affected, all children will be affected.
      else
        retVal[:fault] = "Error: Mother's zygosity for Mitochondrial inheritance must be 'Unaffected' or 'Affected'."
      end

    else # Default case, treat as Autosomal dominant inheritance if type is unknown/invalid
      retVal[:fault] = "Warning: Unknown inheritance type '#{inheritance_type}'. Defaulting to Autosomal dominant inheritance." unless inheritance_type == "Autosomal dominant inheritance"
      if father_zygosity == "None" || mother_zygosity == "None"
        retVal[:fault] = "Error: For autosomal inheritance, neither parent's zygosity can be 'None'."
      else
        f_alleles = get_alleles(father_zygosity)
        m_alleles = get_alleles(mother_zygosity)

        combinations = f_alleles.product(m_alleles).map { |a1, a2| [a1, a2].sort.join('') }
        affected_count = combinations.count { |geno| geno.include?("A") }

        retVal[:kids] = ((affected_count.to_f / combinations.size) * 100).round(2)
      end
    end

    end_time = Time.now # Menambahkan ini untuk menghentikan pengukuran waktu
    retVal[:processing_time_seconds] = (end_time - start_time).round(4) # Menghitung dan menyimpan selisih waktu

    return retVal
  end

  def process_punnet
    calculator_data = params[:calculator]
    submitted_genes = []
    searched_phenotypes = []
    zygosities_p1 = []
    zygosities_p2 = []

    # Buat ID unik untuk submisi ini
    submission_batch_id = SecureRandom.uuid

    if calculator_data.present?
      permitted_input_params = calculator_data.permit(genes: [], zygosities_p1: [], zygosities_p2: [], phenotypes: [])
      session[:last_calculator_input] = permitted_input_params.to_h # Untuk repopulasi form

      submitted_genes = permitted_input_params[:genes]&.reject(&:blank?) || []
      searched_phenotypes = permitted_input_params[:phenotypes]&.reject(&:blank?) || []
      zygosities_p1 = permitted_input_params[:zygosities_p1]&.reject(&:blank?) || []
      zygosities_p2 = permitted_input_params[:zygosities_p2]&.reject(&:blank?) || []
    else
      flash[:alert] = "Input data not received."
      redirect_to punnett_square_calculator_path
      return
    end

    # Validasi input awal (tetap menggunakan flash untuk pesan)
    if submitted_genes.empty?
      flash[:alert] = "Gene inputs are required."
      redirect_to punnett_square_calculator_path
      return
    elsif searched_phenotypes.empty?
      flash[:alert] = "Searched phenotype input is required to display results."
      redirect_to punnett_square_calculator_path
      return
    end

    unless submitted_genes.length == zygosities_p1.length && submitted_genes.length == zygosities_p2.length
      flash[:alert] = "Zygosity data is incomplete or does not match the number of genes submitted. Please check your input."
      redirect_to punnett_square_calculator_path
      return
    end

    # Untuk melacak jumlah keberhasilan dan error untuk pesan flash akhir
    successful_individual_results_count = 0
    error_individual_results_count = 0

    submitted_genes.each_with_index do |gene_name, index|
      api_data_for_gene = {
        gene_name: gene_name,
        jax_gene_id: nil,
        error_message: nil # Error spesifik untuk pemrosesan gen ini sebelum kalkulasi
      }
      puts "PROCESSING GENE: #{gene_name}"

      begin
        # 1a. Search Gene
        gene_search_url = "#{JAX_API_BASE_URL}/search/gene?q=#{CGI.escape(gene_name)}&limit=1"
        gene_search_response = HTTParty.get(gene_search_url, timeout: API_TIMEOUT)

        unless gene_search_response.success? && (parsed_gene_search = gene_search_response.parsed_response).is_a?(Hash) &&
              parsed_gene_search['results'].is_a?(Array) && !parsed_gene_search['results'].empty? &&
              (first_gene_result = parsed_gene_search['results'].first).is_a?(Hash) && first_gene_result['id'].present?
          api_data_for_gene[:error_message] = "Gene '#{gene_name}' not found or API search format is invalid. (Status: #{gene_search_response.code rescue 'N/A'})"
          puts "  ERROR 1a: #{api_data_for_gene[:error_message]}"
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            gene_processing_error: api_data_for_gene[:error_message]
          )
          error_individual_results_count += 1
          next
        end
        api_data_for_gene[:jax_gene_id] = first_gene_result['id']
        puts "  1a. JAX Gene ID: #{api_data_for_gene[:jax_gene_id]}"

        # 1b. Get Gene Annotations
        gene_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:jax_gene_id])}"
        gene_annotation_response = HTTParty.get(gene_annotation_url, timeout: API_TIMEOUT)

        unless gene_annotation_response.success? && (parsed_gene_annotation = gene_annotation_response.parsed_response).is_a?(Hash) &&
               parsed_gene_annotation['diseases'].is_a?(Array)
          api_data_for_gene[:error_message] = "'diseases' annotation format from JAX Gene ID is invalid for '#{api_data_for_gene[:jax_gene_id]}'. (Status: #{gene_annotation_response.code rescue 'N/A'})"
          puts "  ERROR 1b: #{api_data_for_gene[:error_message]}"
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            jax_gene_id: api_data_for_gene[:jax_gene_id],
            gene_processing_error: api_data_for_gene[:error_message]
          )
          error_individual_results_count += 1
          next
        end

        any_omim_match_processed_for_this_gene = false

        parsed_gene_annotation['diseases'].each do |disease_data_from_gene_annotation|
          next unless disease_data_from_gene_annotation.is_a?(Hash) &&
                      disease_data_from_gene_annotation['id']&.start_with?("OMIM:") &&
                      disease_data_from_gene_annotation['name'].present?

          current_omim_id_from_list = disease_data_from_gene_annotation['id']
          current_omim_name_from_list = disease_data_from_gene_annotation['name']

          is_phenotype_match = searched_phenotypes.any? do |user_pheno|
            user_pheno_clean = user_pheno.downcase.strip
            current_omim_name_clean = current_omim_name_from_list.downcase
            current_omim_name_clean.include?(user_pheno_clean) || user_pheno_clean.include?(current_omim_name_clean)
          end

          if is_phenotype_match
            puts "  MATCH FOUND: Gene '#{gene_name}' linked to OMIM Disease '#{current_omim_name_from_list}' (ID: #{current_omim_id_from_list}) which matches user search."
            
            inheritance_type_for_this_match = nil
            omim_details_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(current_omim_id_from_list)}"
            omim_details_response = HTTParty.get(omim_details_url, timeout: API_TIMEOUT)

            if omim_details_response.success? && (parsed_omim_details_for_match = omim_details_response.parsed_response).is_a?(Hash)
              # ... (logika ekstraksi inheritance_type_for_this_match tetap sama) ...
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
            end
            
            any_omim_match_processed_for_this_gene = true
            matched_phenotype_detail_for_this_iteration = [{ name: current_omim_name_from_list, id: current_omim_id_from_list, source: "OMIM Match from Gene Annotation" }]

            calculation_result = calculate_punnet(
              gene_name, current_omim_name_from_list, inheritance_type_for_this_match,
              zygosities_p1[index], zygosities_p2[index]
            )

            GenotypeCalculationResult.create!( # Gunakan create! agar error jika validasi model gagal
              submission_batch_id: submission_batch_id,
              input_gene_name: gene_name,
              jax_gene_id: api_data_for_gene[:jax_gene_id],
              associated_omim_id: current_omim_id_from_list,
              associated_disease_name: current_omim_name_from_list,
              inheritance_type: inheritance_type_for_this_match,
              matched_phenotypes_details_json: matched_phenotype_detail_for_this_iteration,
              calculation_output_json: calculation_result,
              gene_processing_error: nil # Tidak ada error spesifik untuk GEN ini jika sampai sini
            )
            successful_individual_results_count += 1
            puts "  -> GENE '#{gene_name}' - Processed OMIM match: '#{current_omim_name_from_list}'."
          end 
        end 

        if !any_omim_match_processed_for_this_gene && api_data_for_gene[:error_message].nil?
          puts "  -> GENE '#{gene_name}' (JAX ID: #{api_data_for_gene[:jax_gene_id]}) - No OMIM diseases listed for this gene matched the user's searched phenotypes."
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            jax_gene_id: api_data_for_gene[:jax_gene_id],
            gene_processing_error: "No OMIM diseases linked to this gene matched your searched phenotypes."
          )
          error_individual_results_count +=1 # Dihitung sebagai entri "error" atau "tidak ada hasil"
        end

      rescue HTTParty::Error, SocketError => e
        GenotypeCalculationResult.create(
          submission_batch_id: submission_batch_id,
          input_gene_name: gene_name,
          jax_gene_id: api_data_for_gene[:jax_gene_id], # Mungkin nil jika error sebelum ini
          gene_processing_error: "API connection issue: #{e.message}"
        )
        error_individual_results_count += 1
      rescue StandardError => e
        GenotypeCalculationResult.create(
          submission_batch_id: submission_batch_id,
          input_gene_name: gene_name,
          jax_gene_id: api_data_for_gene[:jax_gene_id],
          gene_processing_error: "Unexpected error: #{e.message}"
        )
        error_individual_results_count += 1
        puts "STACKTRACE: #{e.backtrace.join("\n")}"
      end
    end # Akhir dari submitted_genes.each_with_index

    flash[:genotype_submission_batch_id] = submission_batch_id # Simpan ID batch ke flash

    # Set flash messages berdasarkan hasil penyimpanan ke DB
    total_processed_entries = successful_individual_results_count + error_individual_results_count

    if successful_individual_results_count > 0
      flash[:notice] = "Successfully processed and saved #{successful_individual_results_count} result(s) to the database."
      if error_individual_results_count > 0
        flash[:alert_processing_issues] = "#{error_individual_results_count} other input(s) or processing steps encountered errors or yielded no specific match."
      end
    elsif error_individual_results_count > 0 && error_individual_results_count == submitted_genes.length # Semua gen input menghasilkan error/no match
        flash[:alert] = "All #{submitted_genes.length} gene input(s) resulted in an error or no specific phenotype match."
    elsif total_processed_entries == 0 && submitted_genes.any? # Tidak ada yang diproses sama sekali padahal ada input
        flash[:alert] = "Processing could not be completed for the submitted genes."
    elsif submitted_genes.empty? && calculator_data.present? # Ini sudah ditangani di awal, tapi sebagai fallback
      flash[:alert] = "No valid genes were submitted for processing."
    else # Fallback umum
      flash[:info] = "Processing complete. Results (if any) have been saved."
    end
    
    redirect_to punnett_square_calculator_path 
  end

  def calculate_genotype(gene_name, diesease_name, inheritance_type, father_zygosity, mother_zygosity)
    start_time = Time.now

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

    end_time = Time.now # Menambahkan ini untuk menghentikan pengukuran waktu
    retVal[:processing_time_seconds] = (end_time - start_time).round(4)

    return retVal
  end

  def process_genotype
    calculator_data = params[:calculator]
    submitted_genes = []
    searched_phenotypes = []
    zygosities_p1 = []
    zygosities_p2 = []

    # Buat ID unik untuk submisi ini
    submission_batch_id = SecureRandom.uuid

    if calculator_data.present?
      permitted_input_params = calculator_data.permit(genes: [], zygosities_p1: [], zygosities_p2: [], phenotypes: [])
      session[:last_calculator_input] = permitted_input_params.to_h # Untuk repopulasi form

      submitted_genes = permitted_input_params[:genes]&.reject(&:blank?) || []
      searched_phenotypes = permitted_input_params[:phenotypes]&.reject(&:blank?) || []
      zygosities_p1 = permitted_input_params[:zygosities_p1]&.reject(&:blank?) || []
      zygosities_p2 = permitted_input_params[:zygosities_p2]&.reject(&:blank?) || []
    else
      flash[:alert] = "Input data not received."
      redirect_to genotype_calculator_path
      return
    end

    # Validasi input awal (tetap menggunakan flash untuk pesan)
    if submitted_genes.empty?
      flash[:alert] = "Gene inputs are required."
      redirect_to genotype_calculator_path
      return
    elsif searched_phenotypes.empty?
      flash[:alert] = "Searched phenotype input is required to display results."
      redirect_to genotype_calculator_path
      return
    end

    unless submitted_genes.length == zygosities_p1.length && submitted_genes.length == zygosities_p2.length
      flash[:alert] = "Zygosity data is incomplete or does not match the number of genes submitted. Please check your input."
      redirect_to genotype_calculator_path
      return
    end

    # Untuk melacak jumlah keberhasilan dan error untuk pesan flash akhir
    successful_individual_results_count = 0
    error_individual_results_count = 0

    submitted_genes.each_with_index do |gene_name, index|
      api_data_for_gene = {
        gene_name: gene_name,
        jax_gene_id: nil,
        error_message: nil # Error spesifik untuk pemrosesan gen ini sebelum kalkulasi
      }
      puts "PROCESSING GENE: #{gene_name}"

      begin
        # 1a. Search Gene
        gene_search_url = "#{JAX_API_BASE_URL}/search/gene?q=#{CGI.escape(gene_name)}&limit=1"
        gene_search_response = HTTParty.get(gene_search_url, timeout: API_TIMEOUT)

        unless gene_search_response.success? && (parsed_gene_search = gene_search_response.parsed_response).is_a?(Hash) &&
              parsed_gene_search['results'].is_a?(Array) && !parsed_gene_search['results'].empty? &&
              (first_gene_result = parsed_gene_search['results'].first).is_a?(Hash) && first_gene_result['id'].present?
          api_data_for_gene[:error_message] = "Gene '#{gene_name}' not found or API search format is invalid. (Status: #{gene_search_response.code rescue 'N/A'})"
          puts "  ERROR 1a: #{api_data_for_gene[:error_message]}"
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            gene_processing_error: api_data_for_gene[:error_message]
          )
          error_individual_results_count += 1
          next
        end
        api_data_for_gene[:jax_gene_id] = first_gene_result['id']
        puts "  1a. JAX Gene ID: #{api_data_for_gene[:jax_gene_id]}"

        # 1b. Get Gene Annotations
        gene_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:jax_gene_id])}"
        gene_annotation_response = HTTParty.get(gene_annotation_url, timeout: API_TIMEOUT)

        unless gene_annotation_response.success? && (parsed_gene_annotation = gene_annotation_response.parsed_response).is_a?(Hash) &&
               parsed_gene_annotation['diseases'].is_a?(Array)
          api_data_for_gene[:error_message] = "'diseases' annotation format from JAX Gene ID is invalid for '#{api_data_for_gene[:jax_gene_id]}'. (Status: #{gene_annotation_response.code rescue 'N/A'})"
          puts "  ERROR 1b: #{api_data_for_gene[:error_message]}"
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            jax_gene_id: api_data_for_gene[:jax_gene_id],
            gene_processing_error: api_data_for_gene[:error_message]
          )
          error_individual_results_count += 1
          next
        end

        any_omim_match_processed_for_this_gene = false

        parsed_gene_annotation['diseases'].each do |disease_data_from_gene_annotation|
          next unless disease_data_from_gene_annotation.is_a?(Hash) &&
                      disease_data_from_gene_annotation['id']&.start_with?("OMIM:") &&
                      disease_data_from_gene_annotation['name'].present?

          current_omim_id_from_list = disease_data_from_gene_annotation['id']
          current_omim_name_from_list = disease_data_from_gene_annotation['name']

          is_phenotype_match = searched_phenotypes.any? do |user_pheno|
            user_pheno_clean = user_pheno.downcase.strip
            current_omim_name_clean = current_omim_name_from_list.downcase
            current_omim_name_clean.include?(user_pheno_clean) || user_pheno_clean.include?(current_omim_name_clean)
          end

          if is_phenotype_match
            puts "  MATCH FOUND: Gene '#{gene_name}' linked to OMIM Disease '#{current_omim_name_from_list}' (ID: #{current_omim_id_from_list}) which matches user search."
            
            inheritance_type_for_this_match = nil
            omim_details_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(current_omim_id_from_list)}"
            omim_details_response = HTTParty.get(omim_details_url, timeout: API_TIMEOUT)

            if omim_details_response.success? && (parsed_omim_details_for_match = omim_details_response.parsed_response).is_a?(Hash)
              # ... (logika ekstraksi inheritance_type_for_this_match tetap sama) ...
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
            end
            
            any_omim_match_processed_for_this_gene = true
            matched_phenotype_detail_for_this_iteration = [{ name: current_omim_name_from_list, id: current_omim_id_from_list, source: "OMIM Match from Gene Annotation" }]

            calculation_result = calculate_genotype(
              gene_name, current_omim_name_from_list, inheritance_type_for_this_match,
              zygosities_p1[index], zygosities_p2[index]
            )

            GenotypeCalculationResult.create!( # Gunakan create! agar error jika validasi model gagal
              submission_batch_id: submission_batch_id,
              input_gene_name: gene_name,
              jax_gene_id: api_data_for_gene[:jax_gene_id],
              associated_omim_id: current_omim_id_from_list,
              associated_disease_name: current_omim_name_from_list,
              inheritance_type: inheritance_type_for_this_match,
              matched_phenotypes_details_json: matched_phenotype_detail_for_this_iteration,
              calculation_output_json: calculation_result,
              gene_processing_error: nil # Tidak ada error spesifik untuk GEN ini jika sampai sini
            )
            successful_individual_results_count += 1
            puts "  -> GENE '#{gene_name}' - Processed OMIM match: '#{current_omim_name_from_list}'."
          end 
        end 

        if !any_omim_match_processed_for_this_gene && api_data_for_gene[:error_message].nil?
          puts "  -> GENE '#{gene_name}' (JAX ID: #{api_data_for_gene[:jax_gene_id]}) - No OMIM diseases listed for this gene matched the user's searched phenotypes."
          GenotypeCalculationResult.create(
            submission_batch_id: submission_batch_id,
            input_gene_name: gene_name,
            jax_gene_id: api_data_for_gene[:jax_gene_id],
            gene_processing_error: "No OMIM diseases linked to this gene matched your searched phenotypes."
          )
          error_individual_results_count +=1 # Dihitung sebagai entri "error" atau "tidak ada hasil"
        end

      rescue HTTParty::Error, SocketError => e
        GenotypeCalculationResult.create(
          submission_batch_id: submission_batch_id,
          input_gene_name: gene_name,
          jax_gene_id: api_data_for_gene[:jax_gene_id], # Mungkin nil jika error sebelum ini
          gene_processing_error: "API connection issue: #{e.message}"
        )
        error_individual_results_count += 1
      rescue StandardError => e
        GenotypeCalculationResult.create(
          submission_batch_id: submission_batch_id,
          input_gene_name: gene_name,
          jax_gene_id: api_data_for_gene[:jax_gene_id],
          gene_processing_error: "Unexpected error: #{e.message}"
        )
        error_individual_results_count += 1
        puts "STACKTRACE: #{e.backtrace.join("\n")}"
      end
    end # Akhir dari submitted_genes.each_with_index

    flash[:genotype_submission_batch_id] = submission_batch_id # Simpan ID batch ke flash

    # Set flash messages berdasarkan hasil penyimpanan ke DB
    total_processed_entries = successful_individual_results_count + error_individual_results_count

    if successful_individual_results_count > 0
      flash[:notice] = "Successfully processed and saved #{successful_individual_results_count} result(s) to the database."
      if error_individual_results_count > 0
        flash[:alert_processing_issues] = "#{error_individual_results_count} other input(s) or processing steps encountered errors or yielded no specific match."
      end
    elsif error_individual_results_count > 0 && error_individual_results_count == submitted_genes.length # Semua gen input menghasilkan error/no match
        flash[:alert] = "All #{submitted_genes.length} gene input(s) resulted in an error or no specific phenotype match."
    elsif total_processed_entries == 0 && submitted_genes.any? # Tidak ada yang diproses sama sekali padahal ada input
        flash[:alert] = "Processing could not be completed for the submitted genes."
    elsif submitted_genes.empty? && calculator_data.present? # Ini sudah ditangani di awal, tapi sebagai fallback
      flash[:alert] = "No valid genes were submitted for processing."
    else # Fallback umum
      flash[:info] = "Processing complete. Results (if any) have been saved."
    end
    
    redirect_to genotype_calculator_path 
  end

  def phenotype
    if flash[:kalkulasi_results_data]
      @processed_results = flash[:kalkulasi_results_data]
    end

    if flash[:single_disease_calculation_details]
      loaded_data = flash[:single_disease_calculation_details]
      @single_disease_details_all = loaded_data.map { |item| item.deep_symbolize_keys }
    end

    if flash[:combined_disease_probabilities]
      @combined_probabilities_results = flash[:combined_disease_probabilities]
    end
    
    render 'phenotype'
  end

  def process_phenotype
    calculator_params = params[:calculator]

    unless calculator_params.present? &&
           calculator_params[:phenotypes].is_a?(Array) &&
           calculator_params[:phenotypes_p1].is_a?(Array) &&
           calculator_params[:phenotypes_p2].is_a?(Array)
      flash[:alert] = "Input data is incomplete or incorrectly formatted. Please try again."
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
      flash[:alert] = "No valid phenotype name was entered. Please fill in at least one phenotype row completely."
      redirect_to phenotype_calculator_path
      return
    end

    processed_api_data_list = []
    calculation_details_list = []

    user_inputs.each do |input_item|
      current_api_result = {
        "phenotype" => input_item[:name],
        "p1" => input_item[:p1],
        "p2" => input_item[:p2],
        "input_phenotype_name" => input_item[:name],
        "input_parent1_phenotype" => input_item[:p1],
        "input_parent2_phenotype" => input_item[:p2],
        "api_omim_id" => nil,
        "api_disease_name" => nil,
        "api_inheritance_type" => nil,
        "api_error" => nil
      }

      begin
        disease_search_url = "#{JAX_API_BASE_URL}/search/disease?q=#{CGI.escape(input_item[:name])}&limit=-1"
        disease_search_response = HTTParty.get(disease_search_url, timeout: API_TIMEOUT)

        unless disease_search_response.success?
          current_api_result["api_error"] = "Failed to contact disease search API (Status: #{disease_search_response.code})."
          processed_api_data_list << current_api_result
          next
        end
        parsed_disease_search = disease_search_response.parsed_response
        unless parsed_disease_search.is_a?(Hash) && parsed_disease_search['results'].is_a?(Array)
          current_api_result["api_error"] = "Disease search API response format is not correct."
          processed_api_data_list << current_api_result
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
          current_api_result["api_error"] = "No valid OMIM ID found for phenotype '#{input_item[:name]}'."
          processed_api_data_list << current_api_result
          next
        end
        omim_id_from_api = selected_omim_entry['id']
        name_from_api = selected_omim_entry['name']
        current_api_result["api_omim_id"] = omim_id_from_api
        current_api_result["api_disease_name"] = name_from_api.is_a?(String) ? name_from_api : nil

        omim_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(omim_id_from_api)}"
        omim_annotation_response = HTTParty.get(omim_annotation_url, timeout: API_TIMEOUT)
        unless omim_annotation_response.success?
          current_api_result["api_error"] = "Failed to fetch annotation for OMIM ID '#{omim_id_from_api}' (Status: #{omim_annotation_response.code})."
          processed_api_data_list << current_api_result
          next
        end
        parsed_omim_annotation = omim_annotation_response.parsed_response
        unless parsed_omim_annotation.is_a?(Hash)
          current_api_result["api_error"] = "OMIM annotation API response format is not correct."
          processed_api_data_list << current_api_result
          next
        end
        inheritance_info = parsed_omim_annotation.dig('categories', 'Inheritance', 0, 'name')
        if inheritance_info.is_a?(String) && inheritance_info.present?
          current_api_result["api_inheritance_type"] = inheritance_info
        else
          current_api_result["api_error"] = [current_api_result["api_error"], "Inheritance info not found or format is incorrect."].compact.join(" ").strip
        end
        current_api_result["api_error"] = nil if current_api_result["api_error"].blank?
      rescue HTTParty::Error, SocketError, Timeout::Error => e
        Rails.logger.error "JAX API Network Error for phenotype '#{input_item&.[](:name) || 'unknown'}': #{e.class} - #{e.message}"
        current_api_result["api_error"] = "Network error or timeout when calling JAX API: #{e.message}"
      rescue StandardError => e
        log_message = "Unexpected error during API fetch for phenotype "
        log_message += (input_item && input_item[:name]) ? "'#{input_item[:name]}'" : "[unknown phenotype input]"
        log_message += ": #{e.class} - #{e.message}"
        if e.backtrace.is_a?(Array)
          log_message += "\nBacktrace:\n#{e.backtrace.first(10).join("\n")}"
        end
        Rails.logger.error log_message
        current_api_result["api_error"] = "An unexpected internal error occurred while retrieving API data."
      ensure
        processed_api_data_list << current_api_result
      end

      if current_api_result["api_error"].blank? && current_api_result["api_inheritance_type"].present?
        p1_status = current_api_result["input_parent1_phenotype"] == "Present" ? "Positive" : "Negative"
        p2_status = current_api_result["input_parent2_phenotype"] == "Present" ? "Positive" : "Negative"

        calculation_input = {
          "phenotype_name" => current_api_result["phenotype"],
          "parent1_phenotype_status" => p1_status,
          "parent2_phenotype_status" => p2_status,
          "inheritance_type" => current_api_result["api_inheritance_type"]
        }

        begin
          single_disease_result = MendelianCalculatorService.calculate_single_disease_probabilities(calculation_input)
          puts "CONTROLLER DEBUG: single_disease_result FROM SERVICE = #{single_disease_result.inspect}"
          calculation_details_list << single_disease_result
        rescue StandardError => e
            log_message = "Error during Mendelian calculation for phenotype "
            log_message += (current_api_result && current_api_result["phenotype"]) ? "'#{current_api_result["phenotype"]}'" : "[unknown]"
            log_message += ": #{e.class} - #{e.message}"
            if e.backtrace.is_a?(Array)
              log_message += "\nBacktrace:\n#{e.backtrace.first(10).join("\n")}"
            end
            Rails.logger.error log_message
            calculation_details_list << {
                phenotype_name: current_api_result["phenotype"],
                error: "An internal error occurred while performing Mendelian calculations."
            }
        end
      else
        calculation_details_list << {
            phenotype_name: current_api_result["phenotype"],
            error: current_api_result["api_error"] || "Inheritance type not found, calculation cannot continue."
        }
      end
    end

    combined_phenotype_states = [{ states: {}, probability: 1.0 }]
    successful_single_disease_calcs = calculation_details_list.select do |detail|
      detail.is_a?(Hash) && detail[:error].nil? && detail[:final_average_offspring_phenotype_probabilities].present?
    end

    if successful_single_disease_calcs.length > 1
      successful_single_disease_calcs.each do |disease_calc|
        disease_name = disease_calc[:phenotype_name]
        phenotype_probs_for_this_disease = disease_calc[:final_average_offspring_phenotype_probabilities]

        prob_positive = phenotype_probs_for_this_disease["Positive"] || 0.0
        prob_negative = phenotype_probs_for_this_disease["Negative"] || 0.0

        next_combined_phenotype_states = []
        combined_phenotype_states.each do |current_combined_state|
          new_states_positive = current_combined_state[:states].merge({ disease_name => "Positive" })
          new_prob_positive = current_combined_state[:probability] * prob_positive
          next_combined_phenotype_states << { states: new_states_positive, probability: new_prob_positive }

          new_states_negative = current_combined_state[:states].merge({ disease_name => "Negative" })
          new_prob_negative = current_combined_state[:probability] * prob_negative
          next_combined_phenotype_states << { states: new_states_negative, probability: new_prob_negative }
        end
        combined_phenotype_states = next_combined_phenotype_states
      end
      flash[:combined_disease_probabilities] = combined_phenotype_states
    end

    flash[:kalkulasi_results_data] = processed_api_data_list
    flash[:single_disease_calculation_details] = calculation_details_list

    redirect_to phenotype_calculator_path
  end
end