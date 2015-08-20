using Soup;

namespace VSGI.Cookies {

	/**
	 * Extract cookies from the 'Cookie' headers.
	 *
	 * @since 0.2
	 *
	 * @param request
	 */
	public SList<Cookie> from_request (Request request) {
		var cookies     = new SList<Cookie> ();
		var cookie_list = request.headers.get_list ("Cookie");

		if (cookie_list == null)
			return cookies;

		foreach (var cookie in cookie_list.split (","))
			if (cookie != null)
				cookies.prepend (Cookie.parse (cookie, null));

		cookies.reverse ();

		return cookies;
	}

	/**
	 * Extract cookies from the 'Set-Cookie' headers.
	 *
	 * @since 0.2
	 *
	 * @param response
	 */
	public SList<Cookie> from_response (Response response) {
		var cookies     = new SList<Cookie> ();
		var cookie_list = response.headers.get_list ("Set-Cookie");

		if (cookie_list == null)
			return cookies;

		foreach (var cookie in cookie_list.split (","))
			if (cookie != null)
				cookies.prepend (Cookie.parse (cookie, response.request.uri));

		cookies.reverse ();

		return cookies;
	}

	/**
	 * Lookup a cookie by its name.
	 *
	 * The last occurence is returned using a case-sensitive match.
	 *
	 * @since 0.2
	 *
	 * @param cookies cookies typically extracted from {@link VSGI.Cookies.from_request}
	 * @param name    name of the cookie to lookup
	 * @return the cookie if found, otherwise null
	 */
	public Cookie? lookup (SList<Cookie> cookies, string name) {
		Cookie? found = null;

		foreach (var cookie in cookies)
			if (cookie.name == name)
				found = cookie;

		return found;
	}

	/**
	 * Sign the provided cookie name and value using HMAC.
	 *
	 * The returned value will be 'HMAC(checksum_type, name + HMAC(checksum_type, value)) + value'
	 * suitable for a cookie value which can the be verified with {@link VSGI.Cookies.verify}.
	 *
	 * {{
	 * cookie.@value = Cookies.sign (cookie, ChecksumType.SHA512, "super-secret".data);
	 * }}
	 *
	 * @param cookie        cookie to sign
	 * @param checksum_type hash algorithm used to compute the HMAC
	 * @param key           secret used to sign the cookie name and value
	 * @return              the signed value for the provided cookie, which can
	 *                      be reassigned in the cookie
	 */
	public string sign (Cookie cookie, ChecksumType checksum_type, uint8[] key) {
		var checksum = Hmac.compute_for_string (checksum_type,
		                                        key,
		                                        Hmac.compute_for_string (checksum_type, key, cookie.@value) + cookie.name);

		return checksum + cookie.@value;
	}

	/**
	 * Verify a signed cookie from {@link VSGI.Cookies.sign}.
	 *
	 * @param cookie
	 * @param checksum_type hash algorithm used to compute the HMAC
	 * @param key           secret used to sign the cookie's value
	 * @param value         cookie's value extracted from its signature if the
	 *                      verification succeeds, null otherwise
	 * @return              true if the cookie is signed by the secret
	 */
	public bool verify (Cookie cookie, ChecksumType checksum_type, uint8[] key, out string? @value = null) {
		var checksum_length = Hmac.compute_for_string (checksum_type, key, "").length;

		if (cookie.@value.length < checksum_length)
			return false;

		@value = cookie.@value.substring (checksum_length);

		var checksum = Hmac.compute_for_string (checksum_type,
		                                        key,
												Hmac.compute_for_string (checksum_type, key, @value) + cookie.name);

		assert (checksum_length == checksum.length);

		return cookie.@value.substring (0, checksum_length) == checksum;
	}
}