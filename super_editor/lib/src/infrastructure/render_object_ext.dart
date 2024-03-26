import 'package:flutter/rendering.dart';

extension RenderObjectExt on RenderObject {
  Size get size {
    assert(attached);
    if (this is RenderBox) {
      return (this as RenderBox).size;
    }
    if (this is RenderSliver) {
      final sliver = this as RenderSliver;
      return Size(sliver.geometry!.crossAxisExtent ?? sliver.constraints.crossAxisExtent, sliver.geometry!.paintExtent);
    }
    throw Exception('Unknown RenderObject type: $this');
  }

  bool get hasSize {
    assert(attached);
    if (this is RenderBox) {
      return (this as RenderBox).hasSize;
    }
    if (this is RenderSliver) {
      return (this as RenderSliver).geometry != null;
    }
    throw Exception('Unknown RenderObject type: $this');
  }

  Offset globalToLocal(Offset point, {RenderObject? ancestor}) {
    assert(attached);
    if (this is RenderBox) {
      return (this as RenderBox).globalToLocal(point, ancestor: ancestor);
    }
    if (this is RenderSliver) {
      final sliver = this as RenderSliver;
      final transform = sliver.getTransformTo(ancestor);
      transform.invert();
      return MatrixUtils.transformPoint(transform, point);
    }
    throw Exception('Unknown RenderObject type: $this');
  }

  Offset localToGlobal(Offset point, {RenderObject? ancestor}) {
    assert(attached);
    if (this is RenderBox) {
      return (this as RenderBox).localToGlobal(point, ancestor: ancestor);
    }
    if (this is RenderSliver) {
      final sliver = this as RenderSliver;
      final transform = sliver.getTransformTo(ancestor);
      return MatrixUtils.transformPoint(transform, point);
    }
    throw Exception('Unknown RenderObject type: $this');
  }
}
