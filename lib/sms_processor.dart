import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of parsing a raw MFS SMS body.
class _ParsedTransaction {
  final String trxId;
  final String amount;
  final String method;

  const _ParsedTransaction({
    required this.trxId,
    required this.amount,
    required this.method,
  });
}

// ---------------------------------------------------------------------------
// Regex patterns
// ---------------------------------------------------------------------------

// bKash: "... TrxID 8N7A6B5C4D ... Tk 1,250.00 ..."
final RegExp _bkashTrxIdRegex = RegExp(r'TrxID\s+([A-Z0-9]+)');
final RegExp _bkashAmountRegex = RegExp(r'Tk\s+([\d.]+)');

// Nagad: "... TxnID: 9Z8Y7X6W ... Tk 500.00 ..."
final RegExp _nagadTxnIdRegex = RegExp(r'TxnID:\s+([A-Z0-9]+)');
final RegExp _nagadAmountRegex = RegExp(r'Tk\s+([\d.]+)');

/// Entry point invoked for every incoming SMS the Telephony listener
/// captures. Filters by sender signature, extracts the transaction ID and
/// amount for supported MFS providers, and forwards a verification payload
/// to the merchant's WooCommerce REST endpoint.
///
/// [body]      - Raw SMS text body.
/// [sender]    - Raw SMS sender / address field.
/// [targetUrl] - Base site URL, e.g. https://yourstore.com
/// [secretKey] - Merchant-configured shared secret, sent with every request
///               so the WordPress endpoint can authenticate the payload.
Future<void> processMfsSms(
  String body,
  String sender,
  String targetUrl,
  String secretKey,
) async {
  if (body.isEmpty || sender.isEmpty || targetUrl.isEmpty) {
    return;
  }

  final String normalizedSender = sender.toLowerCase();

  _ParsedTransaction? parsed;

  if (normalizedSender.contains('bkash')) {
    parsed = _parseBkash(body);
  } else if (normalizedSender.contains('nagad')) {
    parsed = _parseNagad(body);
  } else {
    // Not a recognized MFS sender — ignore silently.
    return;
  }

  if (parsed == null) {
    // Sender matched a known MFS provider but the body didn't contain a
    // parseable transaction ID / amount pair (e.g. a promo or failed-txn
    // notification). Nothing to forward.
    return;
  }

  await _forwardToWooCommerce(
    targetUrl: targetUrl,
    secretKey: secretKey,
    trxId: parsed.trxId,
    amount: parsed.amount,
    method: parsed.method,
  );
}

// ---------------------------------------------------------------------------
// Provider-specific parsers
// ---------------------------------------------------------------------------

_ParsedTransaction? _parseBkash(String body) {
  final trxMatch = _bkashTrxIdRegex.firstMatch(body);
  final amountMatch = _bkashAmountRegex.firstMatch(body);

  if (trxMatch == null || amountMatch == null) return null;

  final trxId = trxMatch.group(1)?.trim();
  final amount = amountMatch.group(1)?.trim();

  if (trxId == null || trxId.isEmpty || amount == null || amount.isEmpty) {
    return null;
  }

  return _ParsedTransaction(trxId: trxId, amount: amount, method: 'bkash');
}

_ParsedTransaction? _parseNagad(String body) {
  final trxMatch = _nagadTxnIdRegex.firstMatch(body);
  final amountMatch = _nagadAmountRegex.firstMatch(body);

  if (trxMatch == null || amountMatch == null) return null;

  final trxId = trxMatch.group(1)?.trim();
  final amount = amountMatch.group(1)?.trim();

  if (trxId == null || trxId.isEmpty || amount == null || amount.isEmpty) {
    return null;
  }

  return _ParsedTransaction(trxId: trxId, amount: amount, method: 'nagad');
}

// ---------------------------------------------------------------------------
// Network forwarding
// ---------------------------------------------------------------------------

Future<void> _forwardToWooCommerce({
  required String targetUrl,
  required String secretKey,
  required String trxId,
  required String amount,
  required String method,
}) async {
  final Uri endpoint = Uri.parse('$targetUrl/wp-json/softpay/v1/verify');

  final Map<String, String> payload = {
    'secret_key': secretKey,
    'trx_id': trxId,
    'amount': amount,
    'method': method,
  };

  const int maxRetries = 3;
  int attempt = 0;

  while (attempt < maxRetries) {
    attempt++;
    try {
      final response = await http
          .post(
            endpoint,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        // Verified successfully — nothing further to do.
        return;
      }

      // Non-2xx: don't blindly retry client errors (4xx); only retry
      // on server-side / transient failures (5xx).
      if (response.statusCode < 500) {
        return;
      }
    } on TimeoutException {
      // fall through to retry
    } catch (_) {
      // fall through to retry
    }

    if (attempt < maxRetries) {
      await Future.delayed(Duration(seconds: attempt * 2));
    }
  }
}