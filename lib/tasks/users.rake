namespace :users do
  desc "Create an admin user. Usage: bin/rails users:create_admin EMAIL=alice@example.com"
  task create_admin: :environment do
    email = ENV["EMAIL"]
    abort "EMAIL=... required" if email.blank?

    password = ENV["PASSWORD"] || SecureRandom.alphanumeric(24)
    user = User.find_or_initialize_by(email_address: email)
    user.role = :admin
    user.sensitive_data_access = true
    user.password = password
    user.password_confirmation = password
    user.save!

    puts "Admin user #{user.email_address} ready."
    puts "Password: #{password}" if ENV["PASSWORD"].blank?
  end

  desc "List all users with their roles. Usage: bin/rails users:list"
  task list: :environment do
    User.find_each do |u|
      pii = u.sensitive_data_access? ? "[sensitive_data_access]" : ""
      puts "#{u.email_address}\t#{u.role}\t#{pii}"
    end
  end
end
