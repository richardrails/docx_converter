# encoding: UTF-8

# docx_converter -- Converts Word docx files into html or LaTeX via the kramdown syntax
# Copyright (C) 2013 Red (E) Tools Ltd. (www.thebigrede.net)
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

module DocxConverter
  class Parser
    def initialize(options)
      @output_dir = options[:output_dir]
      @docx_filepath = options[:inputfile]

      @image_subdir_filesystem = options[:image_subdir_filesystem]
      @image_subdir_kramdown = options[:image_subdir_kramdown]

      @relationships_hash = {}

      @zipfile = Zip::ZipFile.new(@docx_filepath)
    end

    def parse
      document_xml = unzip_read("word/document.xml")
      footnotes_xml = unzip_read("word/footnotes.xml")
      relationships_xml = unzip_read("word/_rels/document.xml.rels")

      content = Nokogiri::XML(document_xml)
      footnotes = footnotes_xml ? Nokogiri::XML(footnotes_xml) : nil
      relationships = relationships_xml ? Nokogiri::XML(relationships_xml) : nil

      @relationships_hash = parse_relationships(relationships)

      footnote_definitions = parse_footnotes(footnotes)
      output_content = parse_content(content.elements.first,0)

      return {
        :content => output_content,
        :footnote_definitions => footnote_definitions
      }
    end

    private

    def unzip_read(zip_path)
      file = @zipfile.find_entry(zip_path)
      return nil unless file
      contents = ""
      file.get_input_stream do |f|
        contents = f.read
      end
      return contents
    end

    # this is only needed for embedded images
    def extract_image(zip_path)
      file_contents = unzip_read(zip_path)
      extract_basename = File.basename(zip_path, ".*") + ".jpg"
      extract_path = File.join(@output_dir, @image_subdir_filesystem, extract_basename)

      fm = FileMagic.new
      filetype = fm.buffer(file_contents)
      case filetype
        when /^JPEG image data/, /^PNG image data/
          img = Magick::Image.from_blob(file_contents)[0]
          if img.columns > 800 || img.rows > 800
            img.resize_to_fit!(800)
          end
          ret = img.write(extract_path) {
            self.format = "JPEG"
            self.quality = 80
          }
      end
      if @image_subdir_kramdown.empty?
        kramdown_path = extract_basename
      else
        kramdown_path = File.join(@image_subdir_kramdown, extract_basename)
      end
      return kramdown_path
    end

    def parse_relationships(relationships)
      output = {}
      return output unless relationships
      relationships.children.first.children.each do |rel|
        rel_id = rel.attributes["Id"].value
        rel_target = rel.attributes["Target"].value
        output[rel_id] = rel_target
      end
      return output
    end

    def parse_footnotes(node)
      output = {}
      return output unless node
      node.xpath("//w:footnote").each do |fnode|
        footnote_number = fnode.attributes["id"].value
        if ["-1", "0"].include?(footnote_number)
          # Word outputs -1 and 0 as 'magic' footnotes
          next
        end
        output[footnote_number] = parse_content(fnode,0).strip
      end
      return output
    end

    def parse_content(node,depth)
      output = ""
      depth += 1
      children_count = node.children.length
      i = 0

      while i < children_count
        add = ""
        nd = node.children[i]
        case nd.name
        when "body"
          # This is just a container element.
          add = parse_content(nd,depth)

        when "document"
          # This is just a container element.
          add = parse_content(nd,depth)

        when "p"
          # This is a paragraph. In kramdown, paragraphs are spearated by an empty line.
          add = parse_content(nd,depth) + "\n\n"

        when "pPr"
          # This is Word's paragraph-level preset
          add = parse_content(nd,depth)

        when "pStyle"
          # This is a reference to one of Word's paragraph-level styles
          #puts "w:val: #{nd["w:val"]}"
          case nd["w:val"]
            when "Title", "Nadpis"
              add = "{: .class = 'title' }\n"
            when "Heading1", "Nadpis1"

              # require 'ruby-debug'; debugger; true;
              add = "# "
            when "Heading2", "Nadpis2"
              add = "## "
            when "Quote"
              add = "> "
            when "Odrka1", "seznam12", "Odstavecseseznamem"
              add = "* "
            when "seznam12", "Odstavecseseznamem"
              add = "1. "
            when "Odrka2"
              add = "  * "
          end

        when "r"
          # This corresponds to Word's character/inline node. Word's XML is not nested for formatting, wo we cannot descend recursively and 'close' kramdown's formatting in the recursion. Rather, we have to look ahead if this node is formatted, and if yes, set a formatting prefix and postfix which is required for kramdown (e.g. **bold**).
          prefix = postfix = ""
          first_child = nd.children.first

          case first_child.name
          when "rPr"
            # This inline node is formatted. The first child always specifies the formatting of the subsequent 't' (text) node.
            format_node = first_child.children.first
            #puts "fomat node: #{format_node.name}"
            case format_node.name
            when "vertAlign"
              case format_node.attributes["val"].value
              when 'superscript'
                prefix = "<sup>" if nd.text.present?
                postfix = "</sup>" if nd.text.present?
              when 'subscript'
                prefix = "<sub>" if nd.text.present?
                postfix = "</sub>" if nd.text.present?
              end
            when "b"
              # This is regular (non-style) bold
              prefix = postfix = "**" if nd.text.present?
              when "i"
              # This is regular (non-style) italic
              prefix = postfix = "*" if nd.text.present?
            when "smallCaps"
              # This is regular (non-style) italic
              prefix = " name("
              postfix = ")"

            when "rStyle"
              # This is a reference to one of Word's style names
              case format_node.attributes["val"].value
              when "Strong"
                # "Strong" is a predefined Word style
                # This node is missing the xml:space="preserve" attribute, so we need to set the spaces ourselves.
                prefix = " **"  if nd.text.present?
                postfix = "** " if nd.text.present?
              when /Emph.*/
                # "Emph..." is a predefined Word style. In English Word it's 'Emphasis', in French it's 'Emphaseitaliques'
                # This node is missing the xml:space="preserve" attribute, so we need to set the spaces ourselves.
                prefix = " *"  if nd.text.present?
                postfix = "* "  if nd.text.present?
              end
            end
            add = prefix + parse_content(nd,depth) + postfix
          when "br"
            if first_child.attributes.empty?
              # This is a line break. In kramdown, this corresponds to two spaces followed by a newline.
              add = "  \n"
            else first_child.attributes["type"] == "page"
              # this is a Word page break
              add = "<br style='page-break-before:always;'>"
            end

          else
            add = parse_content(nd,depth)
          end


        when "t"
          # this is a regular text node
          add = nd.text

        when "footnoteReference"
          # output the Kramdown footnote syntax
          footnote_number = nd.attributes["id"].value
          add = "[^#{ footnote_number }]"

        when "tbl"
          # parse the table recursively
          add = parse_content(nd,depth)

        when "tr"
          # select all paragraph nodes below the table row and render them into Kramdown syntax
          #table_paragraphs = nd.xpath(".//w:p")
          table_paragraphs = nd.xpath(".//w:tc")
          td = []
          table_paragraphs.each do |tp|
            td << parse_content(tp,depth).tr("\n", " ")
          end
          add = "|" + td.join("|") + "|\n"

        #when "drawing"
          #image_nodes = nd.xpath(".//a:blip", :a => 'http://schemas.openxmlformats.org/drawingml/2006/main')
          #image_node = image_nodes.first
          #if image_node
            #image_id = image_node.attributes["embed"].value
            #image_path_zip = File.join("word", @relationships_hash[image_id])

            #extracted_imagename = extract_image(image_path_zip)

            #add = "![](#{ extracted_imagename })\n"
          #end
        when "hyperlink"
          add = "[#{nd.text}](#{nd.text})"
        else
          # ignore those nodes
          #puts ' ' * depth + "ELSE: #{ nd.name }"
        end

        output += add
        i += 1
      end

      depth -= 1
      return output
    end

  end
end
