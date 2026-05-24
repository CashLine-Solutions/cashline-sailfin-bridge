Mime::Type.register "text/plain", :mmd unless Mime::Type.lookup_by_extension(:mmd)
Mime::Type.register "text/markdown", :md unless Mime::Type.lookup_by_extension(:md)
