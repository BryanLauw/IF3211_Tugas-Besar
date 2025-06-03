# app/controllers/calculator_controller.rb
require 'httparty'
require 'cgi'

class CalculatorController < ApplicationController
  JAX_API_BASE_URL = "https://ontology.jax.org/api/network"
  API_TIMEOUT = 15

  def genotype
    @processed_results = flash[:kalkulasi_results_data] || []
  end

  def process_genotype
    calculator_data = params[:calculator]
    submitted_genes = []
    searched_phenotypes = [] # Fenotip yang dicari pengguna
    zygosities_p1 = []
    zygosities_p2 = []

    if calculator_data.present?
      submitted_genes = calculator_data[:genes]&.reject(&:blank?) || []
      searched_phenotypes = calculator_data[:phenotypes]&.reject(&:blank?) || []
      zygosities_p1 = calculator_data[:zygosities_p1]&.reject(&:blank?) || []
      zygosities_p2 = calculator_data[:zygosities_p2]&.reject(&:blank?) || []
    else
      flash[:alert] = "Tidak ada data input yang diterima."
      redirect_to genotype_calculator_path
      return
    end

    temp_results = []

    # Validasi awal: harus ada gen DAN fenotip yang dicari jika kita hanya mau menyimpan yang cocok
    if submitted_genes.empty?
      flash[:alert] = "Input gen diperlukan."
      redirect_to genotype_calculator_path
      return
    elsif searched_phenotypes.empty?
      flash[:alert] = "Input fenotip yang dicari diperlukan untuk menampilkan hasil."
      # Atau Anda bisa memilih untuk tetap memproses dan menampilkan info gen dasar jika fenotip kosong,
      # tergantung kebutuhan akhir. Untuk permintaan ini, kita anggap fenotip harus ada untuk hasil.
      redirect_to genotype_calculator_path
      return
    end

    submitted_genes.each do |gene_name|
      # Hash sementara untuk menyimpan semua data dari API untuk satu gen ini
      # Kita akan mengumpulkan semua info dulu, baru memutuskan apakah akan dimasukkan ke flash_item_result
      api_data_for_gene = {
        gene_name: gene_name,
        jax_gene_id: nil,
        selected_omim_id: nil,
        omim_main_disease_name: nil,
        inheritance_type: nil,
        # Untuk menampung semua fenotip terkait OMIM dari API, bukan hanya yang cocok
        # Ini bisa berguna jika Anda ingin menampilkan semua fenotip terkait jika tidak ada yang cocok dengan input pengguna
        all_related_omim_phenotypes: [], 
        error_message: nil
      }
      puts "MEMPROSES GEN: #{gene_name}"

      begin
        # 1a. Search Gene
        gene_search_url = "#{JAX_API_BASE_URL}/search/gene?q=#{CGI.escape(gene_name)}&limit=1"
        puts "  1a. URL Gene Search: #{gene_search_url}"
        gene_search_response = HTTParty.get(gene_search_url, timeout: 15)

        unless gene_search_response.success? && (parsed_gene_search = gene_search_response.parsed_response).is_a?(Hash) &&
               parsed_gene_search['results'].is_a?(Array) && !parsed_gene_search['results'].empty? &&
               (first_gene_result = parsed_gene_search['results'].first).is_a?(Hash) && first_gene_result['id'].present?
          api_data_for_gene[:error_message] = "Gen '#{gene_name}' tidak ditemukan atau format API search tidak sesuai. (Status: #{gene_search_response.code rescue 'N/A'})"
          # Catat error tapi jangan langsung next, kita mungkin ingin menyimpan info gen input dengan errornya
          # (akan diputuskan nanti apakah akan dimasukkan ke temp_results)
          puts "  ERROR 1a: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] } # Simpan error ini
          next # Lanjut ke gen berikutnya jika gen awal tidak ditemukan
        end
        api_data_for_gene[:jax_gene_id] = first_gene_result['id']
        puts "  1a. JAX Gene ID: #{api_data_for_gene[:jax_gene_id]}"

        # 1b & 1c. Get Gene Annotations & Find first OMIM ID
        gene_annotation_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:jax_gene_id])}"
        puts "  1b. URL Gene Annotation: #{gene_annotation_url}"
        gene_annotation_response = HTTParty.get(gene_annotation_url, timeout: 15)

        unless gene_annotation_response.success? && (parsed_gene_annotation = gene_annotation_response.parsed_response).is_a?(Hash) &&
               parsed_gene_annotation['diseases'].is_a?(Array)
          api_data_for_gene[:error_message] = "Format anotasi 'diseases' dari JAX Gene ID tidak sesuai untuk '#{api_data_for_gene[:jax_gene_id]}'. (Status: #{gene_annotation_response.code rescue 'N/A'})"
          puts "  ERROR 1b/1c: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        
        omim_disease_entry = parsed_gene_annotation['diseases'].find { |disease| disease.is_a?(Hash) && disease['id']&.start_with?("OMIM:") }
        unless omim_disease_entry && omim_disease_entry['id'].present?
          api_data_for_gene[:error_message] = "OMIM ID tidak ditemukan dalam 'diseases' untuk anotasi gen '#{api_data_for_gene[:jax_gene_id]}'."
          puts "  ERROR 1c: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        api_data_for_gene[:selected_omim_id] = omim_disease_entry['id']
        puts "  1c. OMIM ID dipilih: #{api_data_for_gene[:selected_omim_id]}"

        # 1d. Get OMIM Annotations
        omim_details_url = "#{JAX_API_BASE_URL}/annotation/#{CGI.escape(api_data_for_gene[:selected_omim_id])}"
        puts "  1d. URL OMIM Annotation: #{omim_details_url}"
        omim_details_response = HTTParty.get(omim_details_url, timeout: 15)

        unless omim_details_response.success? && (parsed_omim_details = omim_details_response.parsed_response).is_a?(Hash)
          api_data_for_gene[:error_message] = "Gagal mengambil detail untuk OMIM ID '#{api_data_for_gene[:selected_omim_id]}'. (Status: #{omim_details_response.code rescue 'N/A'})"
          puts "  ERROR 1d: #{api_data_for_gene[:error_message]}"
          temp_results << { input_gene_name: gene_name, error: api_data_for_gene[:error_message] }
          next
        end
        
        # Ambil Nama Penyakit Utama dari OMIM
        if parsed_omim_details['disease'].is_a?(Hash) && parsed_omim_details['disease']['name'].present?
          api_data_for_gene[:omim_main_disease_name] = parsed_omim_details['disease']['name']
          puts "  1d. Penyakit Utama OMIM: #{api_data_for_gene[:omim_main_disease_name]}"
        else
          puts "  1d. Tidak ada objek 'disease' utama atau nama penyakit di detail OMIM."
        end
      
        # Ambil Info Pewarisan
        if parsed_omim_details['categories'].is_a?(Hash) &&
           parsed_omim_details['categories']['Inheritance'].is_a?(Array) &&
           (first_inheritance_info = parsed_omim_details['categories']['Inheritance'].first).is_a?(Hash) &&
           first_inheritance_info['name'].present?
          api_data_for_gene[:inheritance_type] = first_inheritance_info['name']
          puts "  -> Info Pewarisan Ditemukan: #{api_data_for_gene[:inheritance_type]}"
        else
          puts "  -> Tidak ada info 'Inheritance' valid ditemukan di kategori."
        end

        # LANGKAH 1e: Lakukan pencocokan fenotip
        # ====================================
        matched_this_gene_phenotypes = [] # Untuk fenotip yang cocok untuk gen saat ini

        # 1. Cocokkan dengan nama penyakit utama OMIM
        if api_data_for_gene[:omim_main_disease_name].present?
          main_disease_name = api_data_for_gene[:omim_main_disease_name]
          if searched_phenotypes.any? { |user_pheno| main_disease_name.downcase.include?(user_pheno.downcase.strip) || user_pheno.downcase.strip.include?(main_disease_name.downcase) }
            matched_this_gene_phenotypes << {
              name: main_disease_name, # Ambil dari api_data_for_gene atau parsed_omim_details['disease']
              id: api_data_for_gene[:selected_omim_id], # Ini adalah OMIM ID nya
              source: "OMIM Main Disease"
            }
            puts "  1e. COCOK (Penyakit Utama): #{main_disease_name}"
          end
        end

        # 2. Cocokkan dengan semua fenotip di dalam 'categories'
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
                puts "  1e. COCOK (Kategori): #{pheno_name_from_category}"
              end
            end
          end
        end
        
        # HANYA TAMBAHKAN KE TEMP_RESULTS JIKA ADA FENOTIP YANG COCOK
        if matched_this_gene_phenotypes.any?
          flash_item_result = {
            input_gene_name: api_data_for_gene[:gene_name],
            associated_disease_name: api_data_for_gene[:omim_main_disease_name], # Tetap simpan penyakit utama
            inheritance_type: api_data_for_gene[:inheritance_type],
            matched_phenotypes_details: matched_this_gene_phenotypes, # Simpan semua yang cocok
            error: nil # Tidak ada error jika sampai sini dan ada yang cocok
          }
          temp_results << flash_item_result
          puts "  -> GEN '#{gene_name}' MEMILIKI FENOTIP COCOK, DITAMBAHKAN KE HASIL."
        else
          # Tidak ada fenotip yang cocok untuk gen ini, jadi kita tidak menambahkannya ke temp_results
          # kecuali jika Anda ingin menampilkan pesan "tidak ada yang cocok" secara eksplisit per gen.
          # Untuk permintaan Anda, kita lewati.
          puts "  -> GEN '#{gene_name}' TIDAK MEMILIKI FENOTIP COCOK, TIDAK DITAMBAHKAN KE HASIL."
          # Jika Anda ingin tetap menampilkan gen yang diproses meskipun tidak ada fenotip cocok,
          # Anda bisa membuat entri di temp_results dengan pesan khusus di sini.
          # Contoh:
          # temp_results << {
          #   input_gene_name: api_data_for_gene[:gene_name],
          #   associated_disease_name: api_data_for_gene[:omim_main_disease_name],
          #   inheritance_type: api_data_for_gene[:inheritance_type],
          #   error: "Tidak ada fenotip yang cocok dengan input pengguna untuk gen ini."
          # }
        end

      rescue HTTParty::Error, SocketError => e
        # Jika terjadi error koneksi, tetap catat gen ini dengan errornya
        temp_results << { input_gene_name: gene_name, error: "Masalah koneksi API: #{e.message}" }
      rescue StandardError => e
        temp_results << { input_gene_name: gene_name, error: "Kesalahan tak terduga: #{e.message}" }
        puts "STACKTRACE: #{e.backtrace.first(5).join("\n")}"
      end
    end

    flash[:kalkulasi_results_data] = temp_results
    
    if !calculator_data.present? || submitted_genes.empty? && searched_phenotypes.empty?
      # Ini seharusnya sudah ditangani di awal action dengan redirect, tapi sebagai fallback
      flash[:alert] = "Tidak ada data input yang valid untuk diproses."
    else
      # Hitung jumlah gen yang berhasil diproses API (tidak ada error koneksi/API dasar)
      # dan berapa banyak yang menghasilkan kecocokan fenotip.
      
      # genes_processed_without_api_error = 0 # Anda perlu melacak ini di dalam loop jika ingin detail
      # Untuk saat ini, kita akan fokus pada isi temp_results

      successful_matches_count = temp_results.count { |r| r[:error].nil? && r[:matched_phenotypes_details].present? && r[:matched_phenotypes_details].any? }
      error_entries_count = temp_results.count { |r| r[:error].present? }
      
      total_submitted_genes = submitted_genes.count

      if successful_matches_count > 0
        flash[:notice] = "Ditemukan #{successful_matches_count} gen dengan fenotip yang cocok."
        if error_entries_count > 0
          # Ada beberapa yang sukses, beberapa error
          flash[:alert] = "Namun, #{error_entries_count} gen lain mengalami masalah saat diproses atau tidak ditemukan."
        end
      elsif error_entries_count == total_submitted_genes && total_submitted_genes > 0
        # Semua yang di-submit menghasilkan error yang dicatat di temp_results
        flash[:alert] = "Semua #{total_submitted_genes} gen yang dimasukkan mengalami masalah saat diproses."
      elsif error_entries_count > 0 && error_entries_count < total_submitted_genes
        # Beberapa error, sisanya tidak menghasilkan match (karena tidak ada di temp_results)
        flash[:alert] = "#{error_entries_count} gen mengalami masalah. Sisanya tidak menemukan fenotip yang cocok."
      elsif total_submitted_genes > 0 && temp_results.empty?
        # Tidak ada error API yang dicatat, dan tidak ada fenotip cocok, sehingga temp_results kosong
        flash[:info] = "Tidak ditemukan fenotip yang cocok dengan fenotip Anda."
      elsif temp_results.empty? && total_submitted_genes == 0 && calculator_data.present?
         flash[:alert] = "Tidak ada gen yang valid untuk diproses dari input Anda."
      else
        # Fallback jika ada hasil di temp_results tapi tidak masuk kondisi di atas (seharusnya jarang)
        flash[:info] = "Pemrosesan selesai."
      end
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
          current_api_result["api_error"] = "Gagal menghubungi API pencarian penyakit (Status: #{disease_search_response.code})."
          processed_api_data_list << current_api_result
          next
        end
        parsed_disease_search = disease_search_response.parsed_response
        unless parsed_disease_search.is_a?(Hash) && parsed_disease_search['results'].is_a?(Array)
          current_api_result["api_error"] = "Format respons API pencarian penyakit tidak sesuai."
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
          current_api_result["api_error"] = "Tidak ditemukan OMIM ID valid untuk fenotip '#{input_item[:name]}'."
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
          current_api_result["api_error"] = "Gagal mengambil anotasi untuk OMIM ID '#{omim_id_from_api}' (Status: #{omim_annotation_response.code})."
          processed_api_data_list << current_api_result
          next
        end
        parsed_omim_annotation = omim_annotation_response.parsed_response
        unless parsed_omim_annotation.is_a?(Hash)
          current_api_result["api_error"] = "Format respons API anotasi OMIM tidak sesuai."
          processed_api_data_list << current_api_result
          next
        end
        inheritance_info = parsed_omim_annotation.dig('categories', 'Inheritance', 0, 'name')
        if inheritance_info.is_a?(String) && inheritance_info.present?
          current_api_result["api_inheritance_type"] = inheritance_info
        else
          current_api_result["api_error"] = [current_api_result["api_error"], "Info pewarisan tidak ditemukan atau format tidak sesuai."].compact.join(" ").strip
        end
        current_api_result["api_error"] = nil if current_api_result["api_error"].blank?
      rescue HTTParty::Error, SocketError, Timeout::Error => e
        Rails.logger.error "JAX API Network Error for phenotype '#{input_item&.[](:name) || 'unknown'}': #{e.class} - #{e.message}"
        current_api_result["api_error"] = "Kesalahan jaringan atau timeout saat menghubungi JAX API: #{e.message}"
      rescue StandardError => e
        log_message = "Unexpected error during API fetch for phenotype "
        log_message += (input_item && input_item[:name]) ? "'#{input_item[:name]}'" : "[unknown phenotype input]"
        log_message += ": #{e.class} - #{e.message}"
        if e.backtrace.is_a?(Array)
          log_message += "\nBacktrace:\n#{e.backtrace.first(10).join("\n")}"
        end
        Rails.logger.error log_message
        current_api_result["api_error"] = "Terjadi kesalahan internal tidak terduga saat mengambil data API."
      ensure
        processed_api_data_list << current_api_result
      end

      if current_api_result["api_error"].blank? && current_api_result["api_inheritance_type"].present?
        p1_status = current_api_result["input_parent1_phenotype"] == "Ada" ? "Positive" : "Negative"
        p2_status = current_api_result["input_parent2_phenotype"] == "Ada" ? "Positive" : "Negative"

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
                error: "Terjadi kesalahan internal saat melakukan kalkulasi Mendel."
            }
        end
      else
        calculation_details_list << {
            phenotype_name: current_api_result["phenotype"],
            error: current_api_result["api_error"] || "Tipe pewarisan tidak ditemukan, kalkulasi tidak dapat dilanjutkan."
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