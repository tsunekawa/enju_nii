# -*- encoding: utf-8 -*-
module EnjuNii
  module CiNiiBook
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def import_from_cinii_books(options)
        #if options[:isbn]
          lisbn = Lisbn.new(options[:isbn])
          raise EnjuNii::InvalidIsbn unless lisbn.valid?
        #end

        manifestation = Manifestation.find_by_isbn(lisbn.isbn)
        return manifestation if manifestation.present?

        doc = return_rdf(lisbn.isbn)
        raise EnjuNii::RecordNotFound unless doc
        #raise EnjuNii::RecordNotFound if doc.at('//openSearch:totalResults').content.to_i == 0
        import_record_from_cinii_books(doc)
      end

      def import_record_from_cinii_books(doc)
        # http://ci.nii.ac.jp/info/ja/terms.html
        return nil

        ncid = doc.at('//cinii:ncid').try(:content)
        manifestation = Manifestation.where(:ncid => ncid).first if ncid
        return manifestation if manifestation

        creators = get_creator(doc)
        publishers = get_publisher(doc)

        # title
        title = get_title(doc)
        manifestation = Manifestation.new(title)

        # date of publication
        pub_date = doc.at('//dc:date').try(:content)
        if pub_date
          date = pub_date.split('-')
          if date[0] and date[1]
            date = sprintf("%04d-%02d", date[0], date[1])
          else
            date = pub_date
          end
        end
        manifestation.pub_date = pub_date

        language = Language.where(:iso_639_3 => get_language(doc)).first
        if language
          manifestation.language_id = language.id
        else
          manifestation.language_id = 1
        end

        begin
          urn = doc.at("//dcterms:hasPart[@rdf:resource]").attributes["resource"].value
          if urn =~ /^urn:isbn/
            manifestation.isbn = Lisbn.new(urn.gsub(/^urn:isbn:/, ""))
          end
        rescue NoMethodError
        end

        manifestation.carrier_type = CarrierType.where(:name => 'print').first
        manifestation.manifestation_content_type = ContentType.where(:name => 'text').first
        manifestation.ncid = ncid

        if manifestation.valid?
          #Patron.transaction do
            manifestation.save!
            publisher_patrons = Patron.import_patrons(publishers)
            creator_patrons = Patron.import_patrons(creators)
            manifestation.publishers = publisher_patrons
            manifestation.creators = creator_patrons
          #end
        end

        manifestation
      end

      def search_cinii_book(query, options = {})
        options = {:p => 1, :count => 10, :raw => false}.merge(options)
        doc = nil
        results = {}
        startrecord = options[:idx].to_i
        if startrecord == 0
          startrecord = 1
        end
        url = "http://ci.nii.ac.jp/books/opensearch/search?q=#{URI.escape(query)}&p=#{options[:p]}&count=#{options[:count]}&format=rss"
        if options[:raw] == true
          open(url).read
        else
          RSS::RDF::Channel.install_text_element("opensearch:totalResults", "http://a9.com/-/spec/opensearch/1.1/", "?", "totalResults", :text, "opensearch:totalResults")
          RSS::BaseListener.install_get_text_element("http://a9.com/-/spec/opensearch/1.1/", "totalResults", "totalResults=")
          feed = RSS::Parser.parse(url, false)
        end
      end

      def return_rdf(isbn)
        rss = self.search_cinii_by_isbn(isbn)
        if rss.channel.totalResults.to_i == 0
          rss = self.search_cinii_by_isbn(normalize_isbn(isbn))
        end
        if rss.items.first
          Nokogiri::XML(open("#{rss.items.first.link}.rdf").read)
        end
      end

      def search_cinii_by_isbn(isbn)
        url = "http://ci.nii.ac.jp/books/opensearch/search?isbn=#{isbn}&format=rss"
        RSS::RDF::Channel.install_text_element("opensearch:totalResults", "http://a9.com/-/spec/opensearch/1.1/", "?", "totalResults", :text, "opensearch:totalResults")
        RSS::BaseListener.install_get_text_element("http://a9.com/-/spec/opensearch/1.1/", "totalResults", "totalResults=")
        rss = RSS::Parser.parse(url, false)
      end

      private
      def normalize_isbn(isbn)
        if isbn.length == 10
          Lisbn.new(isbn).isbn13
        else
          Lisbn.new(isbn).isbn10
        end
      end

      def get_creator(doc)
        doc.xpath("//foaf:maker/foaf:Person").map{|e|
          {
            :full_name => e.at("./foaf:name").content,
            :full_name_transcription => e.xpath("./foaf:name[@xml:lang]").map{|n| n.content}.join("\n"),
            :patron_identifier => e.attributes["about"].try(:content)
          }
        }
      end

      def get_publisher(doc)
        doc.xpath("//dc:publisher").map{|e| {:full_name => e.content}}
      end

      def get_title(doc)
        {
          :original_title => doc.at("//dc:title[not(@xml:lang)]").content,
          :title_transcription => doc.xpath("//dc:title[@xml:lang]").map{|e| e.try(:content)}.join("\n"),
          :title_alternative => doc.xpath("//dcterms:alternative").map{|e| e.try(:content)}.join("\n")
        }
      end

      def get_language(doc)
        doc.at("//dc:language").try(:content)
      end
    end

    class AlreadyImported < StandardError
    end
  end
end
