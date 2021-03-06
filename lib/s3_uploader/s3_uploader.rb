module S3Uploader
  KILO_SIZE = 1024.0
  BLOCK_SIZE = 1024 * 1024

  def self.upload_directory(source, bucket, options = {})
    options = {
      :destination_dir => '',
      :threads => 5,
      :s3_key => ENV['S3_KEY'],
      :s3_secret => ENV['S3_SECRET'],
      :public => false,
      :region => 'us-east-1',
      :metadata => {},
      :path_style => false,
      :regexp => /.*/,
      :gzip => false,
      :gzip_working_dir => nil,
      :time_range => Time.at(0)..(Time.now + (60 * 60 * 24))
    }.merge(options)

    log = options[:logger] || Logger.new(STDOUT)

    raise 'Source must be a directory' unless File.directory?(source)


    if options[:gzip]
      if options[:gzip_working_dir].nil?
        raise 'gzip_working_dir required when using gzip'
      else
        source_dir = source.end_with?('/') ? source : [ source, '/'].join
        gzip_working_dir = options[:gzip_working_dir].end_with?('/') ?
                              options[:gzip_working_dir] : [ options[:gzip_working_dir], '/'].join

        if gzip_working_dir.start_with?(source_dir)
          raise 'gzip_working_dir may not be located within source-folder'
        end
      end

      options[:gzip_working_dir] = options[:gzip_working_dir].chop if options[:gzip_working_dir].end_with?('/')
    end


    if options[:connection]
      connection = options[:connection]
    else
      raise "Missing access keys" if options[:s3_key].nil? || options[:s3_secret].nil?

      connection = Fog::Storage.new({
          :provider => 'AWS',
          :aws_access_key_id => options[:s3_key],
          :aws_secret_access_key => options[:s3_secret],
          :region => options[:region],
          :path_style => options[:path_style]
      })
    end

    source = source.chop if source.end_with?('/')

    if options[:destination_dir] != '' && !options[:destination_dir].end_with?('/')
      options[:destination_dir] = "#{options[:destination_dir]}/"
    end
    total_size = 0
    files = Queue.new

    Dir.glob("#{source}/**/*").select { |f| !File.directory?(f) }.each do |f|
      if File.basename(f).match(options[:regexp]) && options[:time_range].cover?(File.mtime(f))
        if options[:gzip] && File.extname(f) != '.gz'
          dir, base = File.split(f)
          dir       = dir.sub(source, options[:gzip_working_dir])
          gz_file   = "#{dir}/#{base}.gz"

          FileUtils.mkdir_p(dir) unless File.directory?(dir)
          Zlib::GzipWriter.open(gz_file) do |gz|
            gz.mtime     = File.mtime(f)
            gz.orig_name = f

            File.open(f, 'rb') do |fi|
              while (block_in = fi.read(BLOCK_SIZE)) do
                gz.write block_in
              end
            end
          end

          files << gz_file
          total_size += File.size(gz_file)
        else
          files << f
          total_size += File.size(f)
        end
      end
    end

    directory = connection.directories.new(:key => bucket)

    start = Time.now
    total_files = files.size
    file_number = 0
    @mutex = Mutex.new

    threads = []
    options[:threads].times do |i|
      threads[i] = Thread.new do

        until files.empty?
          @mutex.synchronize do
            file_number += 1
            Thread.current["file_number"] = file_number
          end
          file = files.pop rescue nil
          if file
            key = file.gsub(source, '').gsub(options[:gzip_working_dir].to_s, '')[1..-1]
            dest = "#{options[:destination_dir]}#{key}"
            log.info("[#{Thread.current["file_number"]}/#{total_files}] Uploading #{key} to s3://#{bucket}/#{dest}")

            directory.files.create(
              :key    => dest,
              :body   => File.open(file),
              :public => options[:public],
              :metadata => options[:metadata]
            )
          end
        end
      end
    end
    threads.each { |t| t.join }

    finish = Time.now
    elapsed = finish.to_f - start.to_f
    mins, secs = elapsed.divmod 60.0
    log.info("Uploaded %d (%.#{0}f KB) in %d:%04.2f" % [total_files, total_size / KILO_SIZE, mins.to_i, secs])
  end

  def self.upload_file(source, bucket, options = {})
    options = {
      :destination_dir => '',
      :s3_key => ENV['S3_KEY'],
      :s3_secret => ENV['S3_SECRET'],
      :public => false,
      :region => 'us-east-1',
      :metadata => {},
      :path_style => false
    }.merge(options)

    log = options[:logger] || Logger.new(STDOUT)

    if options[:connection]
      connection = options[:connection]
    else
      raise "Missing access keys" if options[:s3_key].nil? || options[:s3_secret].nil?

      connection = Fog::Storage.new({
          :provider => 'AWS',
          :aws_access_key_id => options[:s3_key],
          :aws_secret_access_key => options[:s3_secret],
          :region => options[:region],
          :path_style => options[:path_style]
      })
    end

    raise 'Source not found' unless File.exist?(source)

    if options[:destination_dir] != '' && !options[:destination_dir].end_with?('/')
      options[:destination_dir] = "#{options[:destination_dir]}/"
    end
    total_size = File.size(source)

    directory = connection.directories.new(:key => bucket)

    start = Time.now
    file_number = 0

    key = File.basename(source)
    dest = "#{options[:destination_dir]}#{key}"
    log.info("Uploading #{key} to s3://#{bucket}/#{dest}")

    directory.files.create(
      :key    => dest,
      :body   => File.open(source),
      :public => options[:public],
      :metadata => options[:metadata]
    )

    finish = Time.now
    elapsed = finish.to_f - start.to_f
    mins, secs = elapsed.divmod 60.0
    log.info("Uploaded (%.#{0}f KB) in %d:%04.2f" % [total_size / KILO_SIZE, mins.to_i, secs])
  end
end
