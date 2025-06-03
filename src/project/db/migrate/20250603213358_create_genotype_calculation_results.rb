class CreateGenotypeCalculationResults < ActiveRecord::Migration[8.0]
  def change
    create_table :genotype_calculation_results do |t|
      t.string :submission_batch_id       # Untuk mengelompokkan hasil dari satu kali submit
      t.string :input_gene_name
      t.string :jax_gene_id, null: true   # Opsional, jadi bisa null
      t.string :associated_omim_id, null: true
      t.string :associated_disease_name, null: true
      t.string :inheritance_type, null: true

      # Untuk PostgreSQL, :jsonb adalah pilihan terbaik untuk kolom JSON.
      # Jika Anda menggunakan SQLite dan versi Rails/SQLite Anda tidak mendukung :jsonb atau :json secara native
      # sebagai tipe kolom yang dioptimalkan, Anda bisa menggunakan :text dan melakukan
      # serialisasi/deserialisasi manual di model Anda atau Rails mungkin akan menanganinya secara dasar.
      # Namun, Rails 7+ dengan SQLite yang lebih baru umumnya mendukung :json dengan baik (disimpan sebagai TEXT).
      # Jika target utama adalah PostgreSQL, :jsonb lebih disarankan.
      t.jsonb :matched_phenotypes_details_json, null: true
      t.jsonb :calculation_output_json, null: true

      t.string :gene_processing_error, null: true # Untuk error terkait pemrosesan gen atau pencarian OMIM

      t.timestamps # Ini akan menambahkan kolom created_at dan updated_at secara otomatis
    end

    # Tambahkan index pada submission_batch_id untuk pencarian yang lebih cepat
    add_index :genotype_calculation_results, :submission_batch_id
  end
end
