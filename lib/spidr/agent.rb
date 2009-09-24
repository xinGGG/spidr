require 'spidr/rules'
require 'spidr/page'
require 'spidr/spidr'

require 'net/http'

module Spidr
  class Agent

    # Proxy to use
    attr_accessor :proxy

    # User-Agent to use
    attr_accessor :user_agent

    # Referer to use
    attr_accessor :referer

    # Delay in between fetching pages
    attr_accessor :delay

    # List of acceptable URL schemes to follow
    attr_reader :schemes

    # History containing visited URLs
    attr_reader :history

    # List of unreachable URLs
    attr_reader :failures

    # Queue of URLs to visit
    attr_reader :queue

    #
    # Creates a new Agent object with the given _options_ and _block_.
    # If a _block_ is given, it will be passed the newly created
    # Agent object.
    #
    # _options_ may contain the following keys:
    # <tt>:proxy</tt>:: The proxy to use while spidering.
    # <tt>:user_agent</tt>:: The User-Agent string to send.
    # <tt>:referer</tt>:: The referer URL to send.
    # <tt>:delay</tt>:: Duration in seconds to pause between spidering each
    #                   link. Defaults to 0.
    # <tt>:schemes</tt>:: The list of acceptable URL schemes to follow.
    #                     Defaults to +http+ and +https+. +https+ URL
    #                     schemes will be ignored if <tt>net/http</tt>
    #                     cannot be loaded.
    # <tt>:host</tt>:: The host-name to visit.
    # <tt>:hosts</tt>:: An +Array+ of host patterns to visit.
    # <tt>:ignore_hosts</tt>:: An +Array+ of host patterns to not visit.
    # <tt>:ports</tt>:: An +Array+ of port patterns to visit.
    # <tt>:ignore_ports</tt>:: An +Array+ of port patterns to not visit.
    # <tt>:links</tt>:: An +Array+ of link patterns to visit.
    # <tt>:ignore_links</tt>:: An +Array+ of link patterns to not visit.
    # <tt>:exts</tt>:: An +Array+ of File extension patterns to visit.
    # <tt>:ignore_exts</tt>:: An +Array+ of File extension patterns to not
    #                         visit.
    # <tt>:queue</tt>:: An initial queue of URLs to visit.
    # <tt>:history</tt>:: An initial list of visited URLs.
    #
    def initialize(options={},&block)
      @proxy = (options[:proxy] || Spidr.proxy)
      @user_agent = (options[:user_agent] || Spidr.user_agent)
      @referer = options[:referer]

      @schemes = []

      if options[:schemes]
        @schemes += options[:schemes]
      else
        @schemes << 'http'

        begin
          require 'net/https'

          @schemes << 'https'
        rescue Gem::LoadError => e
          raise(e)
        rescue ::LoadError
          STDERR.puts "Warning: cannot load 'net/https', https support disabled"
        end
      end

      @host_rules = Rules.new(
        :accept => options[:hosts],
        :reject => options[:ignore_hosts]
      )
      @port_rules = Rules.new(
        :accept => options[:ports],
        :reject => options[:ignore_ports]
      )
      @link_rules = Rules.new(
        :accept => options[:links],
        :reject => options[:ignore_links]
      )
      @ext_rules = Rules.new(
        :accept => options[:exts],
        :reject => options[:ignore_exts]
      )

      @every_url_blocks = []
      @every_failed_url_blocks = []
      @urls_like_blocks = Hash.new { |hash,key| hash[key] = [] }

      @every_page_blocks = []

      @delay = (options[:delay] || 0)
      @history = []
      @failures = []
      @queue = []
      @paused = true

      if options[:host]
        visit_hosts_like(options[:host])
      end

      if options[:queue]
        self.queue = options[:queue]
      end

      if options[:history]
        self.history = options[:history]
      end

      @sessions = Hash.new { |hash,key| hash[key] = {} }

      block.call(self) if block
    end

    #
    # Creates a new Agent object with the given _options_ and will begin
    # spidering at the specified _url_. If a _block_ is given it will be
    # passed the newly created Agent object, before the agent begins
    # spidering.
    #
    def self.start_at(url,options={},&block)
      self.new(options) do |spider|
        block.call(spider) if block

        spider.start_at(url)
      end
    end

    #
    # Creates a new Agent object with the given _options_ and will begin
    # spidering the specified host _name_. If a _block_ is given it will be
    # passed the newly created Agent object, before the agent begins
    # spidering.
    #
    def self.host(name,options={},&block)
      self.new(options.merge(:host => name)) do |spider|
        block.call(spider) if block

        spider.start_at("http://#{name}/")
      end
    end

    #
    # Creates a new Agent object with the given _options_ and will begin
    # spidering the host of the specified _url_. If a _block_ is given it
    # will be passed the newly created Agent object, before the agent
    # begins spidering.
    #
    def self.site(url,options={},&block)
      url = URI(url.to_s)

      return self.new(options.merge(:host => url.host)) do |spider|
        block.call(spider) if block

        spider.start_at(url)
      end
    end

    #
    # Returns the +Array+ of host patterns to visit.
    #
    def visit_hosts
      @host_rules.accept
    end

    #
    # Adds the given _pattern_ to the visit_hosts. If a _block_ is given,
    # it will be added to the visit_hosts.
    #
    def visit_hosts_like(pattern=nil,&block)
      if pattern
        visit_hosts << pattern
      elsif block
        visit_hosts << block
      end

      return self
    end

    #
    # Returns the +Array+ of URL host patterns to not visit.
    #
    def ignore_hosts
      @host_rules.reject
    end

    #
    # Adds the given _pattern_ to the ignore_hosts. If a _block_ is given,
    # it will be added to the ignore_hosts.
    #
    def ignore_hosts_like(pattern=nil,&block)
      if pattern
        ignore_hosts << pattern
      elsif block
        ignore_hosts << block
      end

      return self
    end

    #
    # Returns the +Array+ of URL port patterns to visit.
    #
    def visit_ports
      @port_rules.accept
    end

    #
    # Adds the given _pattern_ to the visit_ports. If a _block_ is given,
    # it will be added to the visit_ports.
    #
    def visit_ports_like(pattern=nil,&block)
      if pattern
        visit_ports << pattern
      elsif block
        visit_ports << block
      end

      return self
    end

    #
    # Returns the +Array+ of URL port patterns to not visit.
    #
    def ignore_ports
      @port_rules.reject
    end

    #
    # Adds the given _pattern_ to the ignore_hosts. If a _block_ is given,
    # it will be added to the ignore_hosts.
    #
    def ignore_ports_like(pattern=nil,&block)
      if pattern
        ignore_ports << pattern
      elsif block
        ignore_ports << block
      end

      return self
    end

    #
    # Returns the +Array+ of link patterns to visit.
    #
    def visit_links
      @link_rules.accept
    end

    #
    # Adds the given _pattern_ to the visit_links. If a _block_ is given,
    # it will be added to the visit_links.
    #
    def visit_links_like(pattern=nil,&block)
      if pattern
        visit_links << pattern
      elsif block
        visit_links << block
      end

      return self
    end

    #
    # Returns the +Array+ of link patterns to not visit.
    #
    def ignore_links
      @link_rules.reject
    end

    #
    # Adds the given _pattern_ to the ignore_links. If a _block_ is given,
    # it will be added to the ignore_links.
    #
    def ignore_links_like(pattern=nil,&block)
      if pattern
        ignore_links << pattern
      elsif block
        ignore_links << block
      end

      return self
    end

    #
    # Returns the +Array+ of URL extension patterns to visit.
    #
    def visit_exts
      @ext_rules.accept
    end

    #
    # Adds the given _pattern_ to the visit_exts. If a _block_ is given,
    # it will be added to the visit_exts.
    #
    def visit_exts_like(pattern=nil,&block)
      if pattern
        visit_exts << pattern
      elsif block
        visit_exts << block
      end

      return self
    end

    #
    # Returns the +Array+ of URL extension patterns to not visit.
    #
    def ignore_exts
      @ext_rules.reject
    end

    #
    # Adds the given _pattern_ to the ignore_exts. If a _block_ is given,
    # it will be added to the ignore_exts.
    #
    def ignore_exts_like(pattern=nil,&block)
      if pattern
        ignore_exts << pattern
      elsif block
        ignore_exts << block
      end

      return self
    end

    #
    # For every URL that the agent visits it will be passed to the
    # specified _block_.
    #
    def every_url(&block)
      @every_url_blocks << block
      return self
    end

    #
    # For every URL that the agent is unable to visit, it will be passed
    # to the specified _block_.
    #
    def every_failed_url(&block)
      @every_failed_url_blocks << block
      return self
    end

    #
    # For every URL that the agent visits and matches the specified
    # _pattern_, it will be passed to the specified _block_.
    #
    def urls_like(pattern,&block)
      @urls_like_blocks[pattern] << block
      return self
    end

    #
    # For every Page that the agent visits, pass the page to the
    # specified _block_.
    #
    def every_page(&block)
      @every_page_blocks << block
      return self
    end

    #
    # For every Page that the agent visits, pass the headers to the given
    # _block_.
    #
    def all_headers(&block)
      every_page { |page| block.call(page.headers) }
    end

    #
    # Clears the history of the agent.
    #
    def clear
      @queue.clear
      @history.clear
      @failures.clear
      return self
    end

    #
    # Start spidering at the specified _url_.
    #
    def start_at(url)
      enqueue(url)

      return continue!
    end

    #
    # Start spidering until the queue becomes empty or the agent is
    # paused.
    #
    def run
      until (@queue.empty? || @paused == true)
        visit_page(dequeue)
      end

      return self
    end

    #
    # Continue spidering.
    #
    def continue!
      @paused = false
      return run
    end

    #
    # Returns +true+ if the agent is still spidering, returns +false+
    # otherwise.
    #
    def running?
      @paused == false
    end

    #
    # Returns +true+ if the agent is paused, returns +false+ otherwise.
    #
    def paused?
      @paused == true
    end

    #
    # Pauses the agent, causing spidering to temporarily stop.
    #
    def pause!
      @paused = true
      return self
    end

    #
    # Sets the list of acceptable URL schemes to follow to the
    # _new_schemes_.
    #
    # @example
    #   agent.schemes = ['http']
    #
    def schemes=(new_schemes)
      @schemes = new_schemes.map { |scheme| scheme.to_s }
    end

    #
    # Sets the history of links that were previously visited to the
    # specified _new_history_.
    #
    # @example
    #   agent.history = ['http://tenderlovemaking.com/2009/05/06/ann-nokogiri-130rc1-has-been-released/']
    #
    def history=(new_history)
      @history = new_history.map do |url|
        unless url.kind_of?(URI)
          URI(url.to_s)
        else
          url
        end
      end
    end

    alias visited_urls history

    #
    # Returns the +Array+ of visited URLs.
    #
    def visited_links
      @history.map { |uri| uri.to_s }
    end

    #
    # Return the +Array+ of hosts that were visited.
    #
    def visited_hosts
      @history.map { |uri| uri.host }.uniq
    end

    #
    # Returns +true+ if the specified _url_ was visited, returns +false+
    # otherwise.
    #
    def visited?(url)
      url = URI(url) unless url.kind_of?(URI)

      return @history.include?(url)
    end

    #
    # Returns +true+ if the specified _url_ was unable to be visited,
    # returns +false+ otherwise.
    #
    def failed?(url)
      url = URI(url) unless url.kind_of?(URI)

      return @failures.include?(url)
    end

    alias pending_urls queue

    #
    # Creates a new Page object from the specified _url_. If a _block_ is
    # given, it will be passed the newly created Page object.
    #
    def get_page(url,&block)
      host = url.host
      port = url.port

      unless url.path.empty?
        path = url.path
      else
        path = '/'
      end

      # append the URL query to the path
      path += "?#{url.query}" if url.query

      begin
        get_session(host,port) do |sess|
          if url.scheme == 'https'
            sess.use_ssl = true
            sess.verify_mode = OpenSSL::SSL::VERIFY_NONE
          end

          headers = {}
          headers['User-Agent'] = @user_agent if @user_agent
          headers['Referer'] = @referer if @referer

          new_page = Page.new(url,sess.get(path,headers))

          block.call(new_page) if block
          return new_page
        end
      rescue SystemCallError, Timeout::Error, Net::HTTPBadResponse
        failed(url)
        return nil
      end
    end

    #
    # Returns the agent represented as a Hash containing the agents
    # +history+ and +queue+ information.
    #
    def to_hash
      {:history => @history, :queue => @queue}
    end

    #
    # Sets the queue of links to visit to the specified _new_queue_.
    #
    # @example
    #   agent.queue = ['http://www.vimeo.com/', 'http://www.reddit.com/']
    #
    def queue=(new_queue)
      @queue = new_queue.map do |url|
        unless url.kind_of?(URI)
          URI(url.to_s)
        else
          url
        end
      end
    end

    #
    # Returns +true+ if the specified _url_ is queued for visiting, returns
    # +false+ otherwise.
    #
    def queued?(url)
      @queue.include?(url)
    end

    #
    # Enqueues the specified _url_ for visiting, only if it passes all the
    # agent's rules for visiting a given URL. Returns +true+ if the _url_
    # was successfully enqueued, returns +false+ otherwise.
    #
    def enqueue(url)
      link = url.to_s
      url = URI(link)

      if (!(queued?(url)) && visit?(url))
        @every_url_blocks.each { |block| block.call(url) }

        @urls_like_blocks.each do |pattern,blocks|
          if ((pattern.kind_of?(Regexp) && link =~ pattern) || pattern == link || pattern == url)
            blocks.each { |url_block| url_block.call(url) }
          end
        end

        @queue << url
        return true
      end

      return false
    end

    protected

    #
    # Returns the Net::HTTP session for the specified _host_ and _port_.
    # If a block is given, it will be passed the Net::HTTP session object.
    #
    def get_session(host,port)
      unless @sessions[host][port]
        session = @sessions[host][port] = Net::HTTP::Proxy(
          @proxy[:host],
          @proxy[:port],
          @proxy[:user],
          @proxy[:password]
        ).start(host,port)
      end

      session = @sessions[host][port]
      block.call(sessions) if block
      return session
    end

    #
    # Dequeues a URL that will later be visited.
    #
    def dequeue
      @queue.shift
    end

    #
    # Returns +true+ if the specified _url_ should be visited, based on
    # it's scheme, returns +false+ otherwise.
    #
    def visit_scheme?(url)
      if url.scheme
        return @schemes.include?(url.scheme)
      else
        return true
      end
    end

    #
    # Returns +true+ if the specified _url_ should be visited, based on
    # the host of the _url_, returns +false+ otherwise.
    #
    def visit_host?(url)
      @host_rules.accept?(url.host)
    end

    #
    # Returns +true+ if the specified _url_ should be visited, based on
    # the port of the _url_, returns +false+ otherwise.
    #
    def visit_port?(url)
      @port_rules.accept?(url.port)
    end

    #
    # Returns +true+ if the specified _url_ should be visited, based on
    # the pattern of the _url_, returns +false+ otherwise.
    #
    def visit_link?(url)
      @link_rules.accept?(url.to_s)
    end

    #
    # Returns +true+ if the specified _url_ should be visited, based on
    # the file extension of the _url_, returns +false+ otherwise.
    #
    def visit_ext?(url)
      @ext_rules.accept?(File.extname(url.path)[1..-1])
    end

    #
    # Returns +true+ if the specified URL should be visited, returns
    # +false+ otherwise.
    #
    def visit?(url)
      (!(visited?(url)) &&
       visit_scheme?(url) &&
       visit_host?(url) &&
       visit_port?(url) &&
       visit_link?(url) &&
       visit_ext?(url))
    end

    #
    # Visits the spedified _url_ and enqueus it's links for visiting. If a
    # _block_ is given, it will be passed a newly created Page object
    # for the specified _url_.
    #
    def visit_page(url,&block)
      get_page(url) do |page|
        @history << page.url

        page.urls.each { |next_url| enqueue(next_url) }

        @every_page_blocks.each { |page_block| page_block.call(page) }

        block.call(page) if block
      end
    end

    #
    # Adds the specified _url_ to the failures list.
    #
    def failed(url)
      url = URI(url.to_s) unless url.kind_of?(URI)

      @every_failed_url_blocks.each { |block| block.call(url) }
      @failures << url
      return true
    end

  end
end
