{
  valid = [
    "a"
    "abc"
    "a0"
    "sample-unit"
    "unit0-segment1"
  ];

  invalid = [
    "0unit"
    "sampleUnit"
    "Sample-unit"
    "sample_unit"
    "sample.unit"
    "-sample-unit"
    "sample-unit-"
    "sample--unit"
  ];
}
