require 'sparql/client'
require 'net/http'
require 'open3'

RSPARQL = SPARQL
module Goo
  module SPARQL
    class Client < RSPARQL::Client

      MIMETYPE_RAPPER_MAP = {
        "application/rdf+xml" => "rdfxml",
        "application/x-turtle" => "turtle",
        "application/n-triples" => "ntriples",
        "text/x-nquads" => "nquads"
      }

      BACKEND_4STORE = "4store"

      def status_based_sleep_time(operation)
        sleep(0.5)
        st = self.status
        if st[:outstanding] > 50
          raise Exception, "Too many outstanding queries. We cannot write to the backend"
        end
        if st[:outstanding] > 0
          return 2.5
        end
        if st[:running] < 4
          return 0.8
        end
        return 1.2
      end

      class DropGraph
        def initialize(g)
          @graph = g
          @caching_options = { :graph => @graph.to_s }
        end
        def to_s
          return "DROP GRAPH <#{@graph.to_s}>"
        end
        def options
          #Returns the caching option
          return @caching_options
        end
      end

      def bnodes_filter_file(file_path,mime_type)
        mime_type = "application/rdf+xml" if mime_type.nil?
        format = MIMETYPE_RAPPER_MAP[mime_type]
        if format.nil?
          raise Exception, "mime_type #{mime_type} not supported in slicing"
        end
        dir = Dir.mktmpdir("file_nobnodes")
        dst_path = File.join(dir,"data.nt")
        dst_path_bnodes_out = File.join(dir,"data_no_bnodes.nt")
        out_format = format == "nquads" ? "nquads" : "ntriples"
        rapper_command_call = "rapper -i #{format} -o #{out_format} #{file_path} > #{dst_path}"
        stdout,stderr,status = Open3.capture3(rapper_command_call)
        if not status.success?
          raise Exception, "Rapper cannot parse #{format} file at #{file_path}: #{stderr}"
        end
        filter_command =
          "LANG=C grep -v '_:genid' #{dst_path} > #{dst_path_bnodes_out}"
        stdout,stderr,status = Open3.capture3(filter_command)
        if not status.success?
          raise Exception, "could not `#{filter_command}`: #{stderr}"
        end
        return dst_path_bnodes_out,dir
      end

      def delete_data_graph(graph)
        Goo.sparql_update_client.update(DropGraph.new(graph))
      end

      def append_triples_no_bnodes(graph,file_path,mime_type_in)
        bnodes_filter = nil
        dir = nil

        if file_path.end_with?("ttl")
          bnodes_filter = file_path
        else
          bnodes_filter,dir = bnodes_filter_file(file_path,mime_type_in)
        end
        mime_type = "text/turtle"

        if mime_type_in == "text/x-nquads"
          mime_type = "text/x-nquads"
          graph = "http://data.bogus.graph/uri"
        end
        data_file = File.read(bnodes_filter)
        params = {method: :post, url: "#{url.to_s}", headers: {"content-type" => mime_type, "mime-type" => mime_type}, timeout: nil}
        backend_name = Goo.sparql_backend_name

        if backend_name == BACKEND_4STORE
          params[:payload] = {
            graph: graph.to_s,
            data: data_file,
            "mime-type" => mime_type
          }
          #for some reason \\\\ breaks parsing
          params[:payload][:data] = params[:payload][:data].split("\n").map { |x| x.sub("\\\\","") }.join("\n")
        else
          params[:url] << "?context=#{CGI.escape("<#{graph.to_s}>")}"
          params[:payload] = data_file
        end

        response = RestClient::Request.execute(params)

        unless dir.nil?
          File.delete(bnodes_filter)

          begin
            FileUtils.rm_rf(dir)
          rescue => e
            puts "Error deleting tmp file #{dir}"
            puts e.backtrace
          end
        end
        response
      end

      def append_data_triples(graph,data,mime_type)
        f = Tempfile.open('data_triple_store')
        f.write(data)
        f.close()
        res = append_triples_no_bnodes(graph,f.path,mime_type)
        return res
      end

      def put_triples(graph,file_path,mime_type=nil)
        if Goo.filter_bnodes?
          delete_graph(graph)
          result =  append_triples_no_bnodes(graph,file_path,mime_type)
          Goo.sparql_query_client.cache_invalidate_graph(graph)
          return result
        end

        params = {
          method: :put,
          url: "#{url.to_s}#{graph.to_s}",
          payload: File.read(file_path),
          headers: {content_type: mime_type},
          timeout: nil
        }
        result = RestClient::Request.execute(params)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        return result
      end

      def append_triples(graph,data,mime_type=nil)
        if Goo.filter_bnodes?
          result = append_data_triples(graph,data,mime_type)
          Goo.sparql_query_client.cache_invalidate_graph(graph)
          return result
        end
        params = {
          method: :post,
          url: "#{url.to_s}",
          payload: {
            graph: graph.to_s,
            data: data,
            "mime-type" => mime_type
          },
          headers: {"mime-type" => mime_type},
          timeout: nil
        }
        result = RestClient::Request.execute(params)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        return result
      end

      def append_triples_from_file(graph,file_path,mime_type=nil)
        if mime_type == "text/nquads" && !graph.instance_of?(Array)
          raise Exception, "Nquads need a list of graphs, #{graph} provided"
        end
        if Goo.filter_bnodes?
          result = append_triples_no_bnodes(graph,file_path,mime_type)
          Goo.sparql_query_client.cache_invalidate_graph(graph)
          return result
        end
        params = {
          method: :post,
          url: "#{url.to_s}",
          payload: {
           graph: graph.to_s,
           data: File.read(file_path),
           "mime-type" => mime_type
          },
          headers: {"mime-type" => mime_type},
          timeout: nil
        }
        result = RestClient::Request.execute(params)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        return result
      end

      def delete_graph(graph)
        result = delete_data_graph(graph)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        return result
      end

      def extract_number_from(i,text)
        res = []
        while (text[i] != '<')
          res << text[i]
          i += 1
        end
        return 0 if res.length == 0
        return res.join("").to_i
      end

      def status
        status_url = (url.to_s.split("/")[0..-2].join "/") + "/status/"
        resp_text =  Net::HTTP.get(URI(status_url))
        running = extract_number_from(230,resp_text)
        out_text = "Outstanding queries</th><td>"
        i_out = resp_text.index(out_text) + out_text.length
        outstanding = extract_number_from(i_out,resp_text)
        return { running: running, outstanding: outstanding }
      end
    end
  end
end
