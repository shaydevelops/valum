/*
 * This file is part of Valum.
 *
 * Valum is free software: you can redistribute it and/or modify it under the
 * terms of the GNU Lesser General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option) any
 * later version.
 *
 * Valum is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Valum.  If not, see <http://www.gnu.org/licenses/>.
 */

using GLib;
using VSGI;

/**
 * Utilities to serve static resources.
 *
 * @since 0.3
 */
[CCode (gir_namespace = "ValumStatic", gir_version = "0.3")]
namespace Valum.Static {

	/**
	 * Flags used to enble or disable options for serving static resources.
	 *
	 * @since 0.3
	 */
	[Flags]
	public enum ServeFlags {
		/**
		 * @since 0.3
		 */
		NONE,
		/**
		 * Produce an 'ETag' header and raise a {@link Valum.Redirection.NOT_MODIFIED}
		 * if the resource has already been transmitted. If not available, it
		 * will fallback on either {@link Valum.Static.ServeFlags.ENABLE_LAST_MODIFIED}
		 * or no caching at all.
		 *
		 * @since 0.3
		 */
		ENABLE_ETAG,
		/**
		 * Produce a 'Last-Modified' header and raise a {@link Valum.Redirection.NOT_MODIFIED}
		 * if the resource has already been transmitted.
		 *
		 * If {@link Valum.ServeFlags.ENABLE_ETAG} is specified and available,
		 * it will be used instead.
		 *
		 * @since 0.3
		 */
		ENABLE_LAST_MODIFIED,
		/**
		 * Indicate that the delivered resource can be cached by anyone using
		 * the 'Cache-Control: public' header.
		 *
		 * @since 0.3
		 */
		ENABLE_CACHE_CONTROL_PUBLIC,
		/**
		 * Raise a {@link ClientError.FORBIDDEN} if rights are missing on the
		 * resource rather than calling 'next'.
		 *
		 * @since 0.3
		 */
		FORBID_ON_MISSING_RIGHTS,
		/**
		 * If supported, generate a 'X-Sendfile' header instead of delivering
		 * the actual resource in the response body.
		 *
		 * The absolute path as provided by {@link GLib.File.get_path} will be
		 * produced in the 'X-Sendfile' header. It must therefore be accessible
		 * for the HTTP server, otherwise it will silently fallback to serve the
		 * resource directly.
		 *
		 * @since 0.3
		 */
		X_SENDFILE
	}

	/**
	 * Serve static files relative to a given root.
	 *
	 * The path to relative to the root is expected to be associated to the
	 * 'path' key in the routing context.
	 *
	 * The path can be local or remote given that GVFS can be used.
	 *
	 * The 'ETag' header is obtained from {@link GLib.FileAttribute.ETAG_VALUE}.
	 *
	 * If the file is not found, the request is delegated to the next
	 * middleware.
	 *
	 * If the file is not readable, a '403 Forbidden' is raised.
	 *
	 * @since 0.3
	 *
	 * @param root        path from which resources are resolved
	 * @param serve_flags flags for serving the resources
	 */
	public HandlerCallback serve_from_file (File root, ServeFlags serve_flags = ServeFlags.NONE) {
		return (req, res, next, ctx) => {
			var file = root.resolve_relative_path (ctx["path"].get_string ());

			try {
				var file_info = file.query_info ("%s,%s,%s".printf (FileAttribute.ETAG_VALUE,
				                                                    FileAttribute.TIME_MODIFIED,
				                                                    FileAttribute.STANDARD_SIZE),
				                                 FileQueryInfoFlags.NONE);

				var etag          = file_info.get_etag ();
				var last_modified = file_info.get_modification_time ();

				if (etag != null && ServeFlags.ENABLE_ETAG in serve_flags) {
					if ("\"%s\"".printf (etag) == req.headers.get_one ("If-None-Match"))
						throw new Redirection.NOT_MODIFIED ("");
					res.headers.replace ("ETag", "\"%s\"".printf (etag));
				}

				else if (last_modified.tv_sec > 0 && ServeFlags.ENABLE_LAST_MODIFIED in serve_flags) {
					var if_modified_since = req.headers.get_one ("If-Modified-Since");
					if (if_modified_since != null && new Soup.Date.from_string (if_modified_since).to_timeval ().tv_sec >= last_modified.tv_sec)
						throw new Redirection.NOT_MODIFIED ("");
					res.headers.replace ("Last-Modified", new Soup.Date.from_time_t (last_modified.tv_sec).to_string (Soup.DateFormat.HTTP));
				}

				if (ServeFlags.ENABLE_CACHE_CONTROL_PUBLIC in serve_flags)
					res.headers.append ("Cache-Control", "public");

				var file_read_stream = file.read ();

				// read 128 bytes for the content-type guess
				var contents = new uint8[128];
				file_read_stream.read_all (contents, null);

				// reposition the stream
				file_read_stream.seek (0, SeekType.SET);

				bool uncertain;
				res.headers.set_content_type (ContentType.guess (file.get_basename (), contents, out uncertain), null);
				if (res.headers.get_list ("Content-Encoding") == null)
					res.headers.set_content_length (file_info.get_size ());

				if (uncertain)
					warning ("could not infer content type of file '%s' with certainty", file.get_uri ());

				if (ServeFlags.X_SENDFILE in serve_flags && file.get_path () != null) {
					res.headers.set_encoding (Soup.Encoding.NONE);
					res.headers.replace ("X-Sendfile", file.get_path ());
					return res.end ();
				}

				if (req.method == Request.HEAD)
					return res.end ();

				res.body.splice (file_read_stream, OutputStreamSpliceFlags.CLOSE_SOURCE);
				return true;
			} catch (FileError.ACCES fe) {
				if (ServeFlags.FORBID_ON_MISSING_RIGHTS in serve_flags) {
					throw new ClientError.FORBIDDEN ("You are cannot access this resource.");
				} else {
					return next ();
				}
			} catch (FileError.NOENT fe) {
				return next ();
			}
		};
	}

	/**
	 * @since 0.3
	 */
	public HandlerCallback serve_from_path (string path, ServeFlags serve_flags = ServeFlags.NONE) {
		return serve_from_file (File.new_for_path (path), serve_flags);
	}

	/**
	 * @since 0.3
	 */
	public HandlerCallback serve_from_uri (string uri, ServeFlags serve_flags = ServeFlags.NONE) {
		return serve_from_file (File.new_for_uri (uri), serve_flags);
	}

	/**
	 * Serve files from the provided {@link GLib.Resource} bundle.
	 *
	 * The 'ETag' header is obtained from a SHA1 checksum.
	 *
	 * [[http://valadoc.org/#!api=gio-2.0/GLib.Resource]]
	 *
	 * @see Valum.Static.serve_from_file
	 * @see GLib.resources_open_stream
	 * @see GLib.resources_lookup_data
	 *
	 * @since 0.3
	 *
	 * @param resource    resource bundle to serve
	 * @param prefix      prefix from which resources are resolved in the
	 *                    resource bundle; a valid prefix begin and start with a
	 *                    '/' character
	 * @param serve_flags flags for serving the resources
	 */
	public HandlerCallback serve_from_resource (Resource   resource,
	                                            string     prefix      = "/",
	                                            ServeFlags serve_flags = ServeFlags.NONE) {
		// cache for already computed 'ETag' values
		var etag_cache = new HashTable <string, string> (str_hash, str_equal);

		return (req, res, next, ctx) => {
			var path = "%s%s".printf (prefix, ctx["path"].get_string ());

			Bytes lookup;
			try {
				lookup = resource.lookup_data (path, ResourceLookupFlags.NONE);
			} catch (Error err) {
				return next ();
			}

			if (ServeFlags.ENABLE_ETAG in serve_flags) {
				var etag = path in etag_cache ?
					etag_cache[path] :
					"\"%s\"".printf (Checksum.compute_for_bytes (ChecksumType.SHA1, lookup));

				etag_cache[path] = etag;

				if (etag == req.headers.get_one ("If-None-Match"))
					throw new Redirection.NOT_MODIFIED ("");

				res.headers.replace ("ETag", etag);
			}

			if (ServeFlags.ENABLE_CACHE_CONTROL_PUBLIC in serve_flags)
				res.headers.append ("Cache-Control", "public");

			// set the content-type based on a good guess
			bool uncertain;
			res.headers.set_content_type (ContentType.guess (path, lookup.get_data (), out uncertain), null);
			if (res.headers.get_list ("Content-Encoding") == null)
				res.headers.set_content_length (lookup.get_size ());

			if (uncertain)
				warning ("could not infer content type of file '%s' with certainty", path);

			if (req.method == Request.HEAD)
				return res.end ();

			var file = resource.open_stream (path, ResourceLookupFlags.NONE);

			// transfer the file
			res.body.splice (file, OutputStreamSpliceFlags.CLOSE_SOURCE);
			return true;
		};
	}
}