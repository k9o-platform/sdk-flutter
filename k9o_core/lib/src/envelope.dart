/// 2xx response envelope `{data, meta}`; `meta` is empty when absent.
class Envelope<T> {
  final T data;
  final Map<String, dynamic> meta;
  const Envelope(this.data, this.meta);
}
