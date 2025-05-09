requires "IO::Async" => "0.802";
requires "Future" => "0.48";
requires "Future::AsyncAwait" => "0.62";
requires "HTTP::Request" => "6.36";
requires "HTTP::Response" => "6.36";

on test => sub {
    requires "Test2::V0" => "0.000145";
    requires "Future::HTTP" => "0.15";
};
