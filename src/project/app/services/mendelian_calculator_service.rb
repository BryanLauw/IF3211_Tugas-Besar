class MendelianCalculatorService

  def self.calculate_single_disease_probabilities(input_data)
    puts "SERVICE DEBUG: input_data = #{input_data.inspect}"

    phenotype_name = input_data["phenotype_name"]
    p1_pheno_status = input_data["parent1_phenotype_status"]
    p2_pheno_status = input_data["parent2_phenotype_status"]
    
    inheritance_type_from_input = input_data["inheritance_type"] 
    inheritance_type_string = inheritance_type_from_input&.downcase || ""

    puts "SERVICE DEBUG: phenotype_name='#{phenotype_name}', p1_status='#{p1_pheno_status}', p2_status='#{p2_pheno_status}', inheritance_original='#{inheritance_type_from_input}', inheritance_processed='#{inheritance_type_string}'"

    if inheritance_type_string.include?("mitochondrial")
      mother_pheno_status = input_data["parent1_phenotype_status"] 
      
      final_pheno_probs = {}
      final_geno_probs = {} 

      if mother_pheno_status == "Positive"
        final_pheno_probs = { "Positive" => 1.0, "Negative" => 0.0 }
        final_geno_probs = { "Affected_mtDNA" => 1.0 } 
      elsif mother_pheno_status == "Negative"
        final_pheno_probs = { "Positive" => 0.0, "Negative" => 1.0 }
        final_geno_probs = { "Normal_mtDNA" => 1.0 } 
      else
        return {
          phenotype_name: input_data["phenotype_name"],
          parent1_phenotype_status: mother_pheno_status,
          parent2_phenotype_status: input_data["parent2_phenotype_status"], 
          inheritance_type: input_data["inheritance_type"],
          error: "Invalid mother phenotype status ('#{mother_pheno_status}') for Mitochondrial Inheritance.",
          possible_mother_genotypes: [], possible_father_genotypes: [],
          num_parent_genotype_scenarios: 0, parent_genotype_scenarios_details: [],
          final_average_offspring_genotype_probabilities: {},
          final_average_offspring_phenotype_probabilities: {}
        }
      end

      return {
        phenotype_name: input_data["phenotype_name"],
        parent1_phenotype_status: mother_pheno_status,
        parent2_phenotype_status: input_data["parent2_phenotype_status"], 
        inheritance_type: input_data["inheritance_type"],
        possible_mother_genotypes: [mother_pheno_status == "Positive" ? "Affected_mtDNA_Parent" : "Normal_mtDNA_Parent"], 
        possible_father_genotypes: ["Not_Relevant_mtDNA"], 
        num_parent_genotype_scenarios: 1, 
        parent_genotype_scenarios_details: [{ 
            mother_genotype: (mother_pheno_status == "Positive" ? "Affected_mtDNA_Parent" : "Normal_mtDNA_Parent"),
            father_genotype: "Not_Relevant_mtDNA",
            offspring_genotype_probabilities: final_geno_probs,
            offspring_phenotype_probabilities: final_pheno_probs
        }],
        final_average_offspring_genotype_probabilities: final_geno_probs,
        final_average_offspring_phenotype_probabilities: final_pheno_probs,
        error: nil
      }
    end 

    mother_pheno_status = p1_pheno_status
    father_pheno_status = p2_pheno_status
    
    possible_mother_genotypes = get_possible_parent_genotypes(mother_pheno_status, inheritance_type_string, "female")
    possible_father_genotypes = get_possible_parent_genotypes(father_pheno_status, inheritance_type_string, "male")
    
    if possible_mother_genotypes.empty? || possible_father_genotypes.empty?
      return {
        phenotype_name: phenotype_name,
        parent1_phenotype_status: p1_pheno_status,
        parent2_phenotype_status: p2_pheno_status,
        inheritance_type: inheritance_type_from_input, 
        possible_mother_genotypes: [],
        possible_father_genotypes: [],
        num_parent_genotype_scenarios: 0,
        parent_genotype_scenarios_details: [],
        final_average_offspring_genotype_probabilities: {},
        final_average_offspring_phenotype_probabilities: {},
        error: "Could not determine possible parent genotypes for '#{phenotype_name || 'Unknown Phenotype'}' given phenotypes and inheritance type '#{inheritance_type_from_input || 'Unknown Inheritance'}'. Possible reason: inheritance type not supported or inconsistent parent phenotypes."
      }
    end

    all_scenarios_details = []
    cumulative_offspring_genotype_probs = Hash.new(0.0)
    cumulative_offspring_phenotype_probs = Hash.new(0.0)
    num_parent_genotype_pairs = 0

    possible_mother_genotypes.each do |mother_geno|
      possible_father_genotypes.each do |father_geno|
        num_parent_genotype_pairs += 1
        
        punnett_results = calculate_punnett_square(mother_geno, father_geno, inheritance_type_string)

        all_scenarios_details << {
          mother_genotype: mother_geno,
          father_genotype: father_geno,
          offspring_genotype_probabilities: punnett_results[:offspring_genotype_probabilities],
          offspring_phenotype_probabilities: punnett_results[:offspring_phenotype_probabilities]
        }

        punnett_results[:offspring_genotype_probabilities].each do |genotype, prob|
          cumulative_offspring_genotype_probs[genotype] += prob
        end
        punnett_results[:offspring_phenotype_probabilities].each do |phenotype, prob|
          cumulative_offspring_phenotype_probs[phenotype] += prob
        end
      end
    end

    final_avg_offspring_genotype_probs = Hash.new(0.0)
    cumulative_offspring_genotype_probs.each do |genotype, total_prob|
      final_avg_offspring_genotype_probs[genotype] = total_prob / num_parent_genotype_pairs.to_f 
    end

    final_avg_offspring_phenotype_probs = Hash.new(0.0)
    cumulative_offspring_phenotype_probs.each do |phenotype, total_prob|
      final_avg_offspring_phenotype_probs[phenotype] = total_prob / num_parent_genotype_pairs.to_f 
    end
    
    return { 
      phenotype_name: phenotype_name,
      parent1_phenotype_status: p1_pheno_status,
      parent2_phenotype_status: p2_pheno_status,
      inheritance_type: inheritance_type_from_input, 
      possible_mother_genotypes: possible_mother_genotypes,
      possible_father_genotypes: possible_father_genotypes,
      num_parent_genotype_scenarios: num_parent_genotype_pairs,
      parent_genotype_scenarios_details: all_scenarios_details,
      final_average_offspring_genotype_probabilities: final_avg_offspring_genotype_probs,
      final_average_offspring_phenotype_probabilities: final_avg_offspring_phenotype_probs,
      error: nil
    }
  end

  private

  def self.get_possible_parent_genotypes(phenotype_status, inheritance_type_string, sex)
    puts "GET_GENO DEBUG: status='#{phenotype_status}', inheritance_processed='#{inheritance_type_string}', sex='#{sex}'"
    status = phenotype_status 
    genotypes = []
    case inheritance_type_string 
    when /autosomal dominant/
      if status == "Positive"
        genotypes = ["AA", "Aa"] 
      else 
        genotypes = ["aa"]
      end
    when /autosomal recessive/
      if status == "Positive"
        genotypes = ["aa"] 
      else 
        genotypes = ["AA", "Aa"]
      end
    when /x-linked dominant/
      if sex == "female"
        if status == "Positive"
          genotypes = ["XAXA", "XAXa"]
        else 
          genotypes = ["XaXa"]
        end
      else 
        if status == "Positive"
          genotypes = ["XAY"]
        else 
          genotypes = ["XaY"]
        end
      end
    when /x-linked recessive/
      if sex == "female"
        if status == "Positive"
          genotypes = ["XaXa"]
        else 
          genotypes = ["XAXA", "XAXa"]
        end
      else 
        if status == "Positive"
          genotypes = ["XaY"]
        else 
          genotypes = ["XAY"]
        end
      end
    when /y-linked/
      if sex == "female"
        if phenotype_status == "Positive"
          Rails.logger.warn "Inconsistent input: Female parent cannot be 'Positive' for a Y-linked trait. Phenotype: #{phenotype_status}"
          genotypes = [] 
        else 
          genotypes = ["XX"]
        end
      else 
        if phenotype_status == "Positive"
          genotypes = ["XYa"] 
        else 
          genotypes = ["XYA"] 
        end
      end
    else
      Rails.logger.warn "Unknown or unhandled inheritance type: '#{inheritance_type_string}' in get_possible_parent_genotypes"
      genotypes = [] 
    end
    puts "GET_GENO DEBUG: result_genotypes=#{genotypes.inspect} for status='#{status}', inheritance_processed='#{inheritance_type_string}', sex='#{sex}'"
    genotypes
  end

  def self.calculate_punnett_square(mother_geno, father_geno, inheritance_type_string)
    offspring_genotypes_counts = Hash.new(0)
    total_combinations = 0

    mother_gametes = get_gametes(mother_geno, inheritance_type_string, "female")
    father_gametes = get_gametes(father_geno, inheritance_type_string, "male")

    mother_gametes.each do |m_gamete|
      father_gametes.each do |f_gamete|
        offspring_geno = combine_gametes(m_gamete, f_gamete, inheritance_type_string)
        offspring_genotypes_counts[offspring_geno] += 1
        total_combinations += 1
      end
    end
    
    offspring_genotype_probabilities = Hash.new(0.0)
    offspring_genotypes_counts.each do |geno, count|
      offspring_genotype_probabilities[geno] = count.to_f / total_combinations
    end

    offspring_phenotype_probabilities = determine_phenotypes_from_genotypes(offspring_genotype_probabilities, inheritance_type_string)
    {
      offspring_genotype_probabilities: offspring_genotype_probabilities,
      offspring_phenotype_probabilities: offspring_phenotype_probabilities
    }
  end

  def self.get_gametes(parent_genotype, inheritance_type_string, sex)
    puts "GET_GAMETES DEBUG: parent_genotype='#{parent_genotype}', inheritance_processed='#{inheritance_type_string}', sex='#{sex}'"
    gametes = []

    if inheritance_type_string.include?("autosomal")
      gametes = [parent_genotype[0], parent_genotype[1]]
    elsif inheritance_type_string.include?("x-linked")
      if sex == "female" 
        unless parent_genotype.length == 4 && parent_genotype.upcase.count("X") == 2
            Rails.logger.error "Invalid X-linked female genotype format for gamete extraction: #{parent_genotype}"
            return [] 
        end
        gametes = [parent_genotype[0..1], parent_genotype[2..3]]
      else 
        unless parent_genotype.length == 3 && parent_genotype.upcase.start_with?("X") && parent_genotype.upcase.end_with?("Y")
             Rails.logger.error "Invalid X-linked male genotype format for gamete extraction: #{parent_genotype}"
            return []
        end
        gametes = [parent_genotype[0..1], parent_genotype[2]] 
      end
    elsif inheritance_type_string.include?("y-linked")
      if sex == "female" && parent_genotype == "XX"
        gametes = ["X"] 
      elsif sex == "male" && (parent_genotype == "XYA" || parent_genotype == "XYa")
        gametes = [parent_genotype[0], parent_genotype[1..2]] 
      else
        Rails.logger.warn "Unhandled case or invalid genotype in get_gametes for Y-linked: sex=#{sex}, genotype=#{parent_genotype}"
        return [] 
      end
    else
      Rails.logger.warn "Unknown inheritance pattern in get_gametes: #{inheritance_type_string}"
    end
    
    result = gametes.uniq
    puts "GET_GAMETES DEBUG: result_gametes_uniq=#{result.inspect} for parent_genotype='#{parent_genotype}'"
    return result
  end

  def self.combine_gametes(gamete1, gamete2, inheritance_type_string)
    if inheritance_type_string.include?("autosomal")
      return [gamete1, gamete2].sort.join
    elsif inheritance_type_string.include?("x-linked")
      if gamete1.start_with?("X") && gamete2.start_with?("X")
        return "#{gamete1}#{gamete2}" 
      elsif gamete1.start_with?("X") && gamete2 == "Y"
        return "#{gamete1}Y" 
      else
        Rails.logger.error "Invalid gamete combination for X-linked: #{gamete1}, #{gamete2}"
        return "ERROR_COMBO_XL"
      end
    elsif inheritance_type_string.include?("y-linked")
      if gamete1 == "X"
        if gamete2 == "X" 
          return "XX"   
        elsif gamete2 == "YA" || gamete2 == "Ya" 
          return "X#{gamete2}"
        else
          Rails.logger.error "Invalid male gamete for Y-linked combination: #{gamete2}"
          return "ERROR_COMBO_YL_MG" 
        end
      else
        Rails.logger.error "Invalid female gamete for Y-linked combination (should be 'X'): #{gamete1}"
        return "ERROR_COMBO_YL_FG" 
      end
    else
      Rails.logger.warn "Unknown inheritance type for combine_gametes: #{inheritance_type_string}"
      return "#{gamete1}#{gamete2}"
    end
  end

  def self.determine_phenotypes_from_genotypes(offspring_genotype_probs_map, inheritance_type_string)
    phenotype_probs = Hash.new(0.0)
    offspring_genotype_probs_map.each do |genotype, prob|
      is_positive = false
      case inheritance_type_string
      
      when /autosomal dominant/ 
        is_positive = genotype.gsub('a','').include?('A') 
      when /autosomal recessive/ 
        is_positive = (genotype == 'aa')
      when /x-linked dominant/ 
        is_positive = genotype.gsub('Xa','B').include?('A') 
      when /x-linked recessive/ 
        is_positive = (genotype == 'XaXa' || genotype == 'XaY')
      when /y-linked/
        is_positive = (genotype == "XYa")
      else
        is_positive = false
      end
      
      if is_positive
        phenotype_probs["Positive"] += prob
      else
        phenotype_probs["Negative"] += prob
      end
    end
    
    puts "DETERMINE_PHENOTYPES DEBUG: offspring_genotypes=#{offspring_genotype_probs_map.keys.join(', ')}, results=#{phenotype_probs.inspect}"
    phenotype_probs
  end
end