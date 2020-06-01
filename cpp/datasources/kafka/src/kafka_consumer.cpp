/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "kafka_consumer.hpp"
#include <memory>

namespace cudf {
namespace io {
namespace external {
namespace kafka {

std::unique_ptr<cudf::io::datasource::buffer> kafka_consumer::host_read(size_t offset, size_t size)
{
  auto datasource_buffer = std::make_unique<message_buffer>("\n");

  while (datasource_buffer->size() < size) {
    RdKafka::Message *msg = consumer_->consume(default_timeout_);
    if (msg->err() == RdKafka::ErrorCode::ERR_NO_ERROR) { datasource_buffer->add_message(msg); }
    delete msg;
  }

  return datasource_buffer;
}

kafka_consumer::kafka_consumer(std::map<std::string, std::string> configs)
{
  kafka_conf_ = std::unique_ptr<RdKafka::Conf>(RdKafka::Conf::create(RdKafka::Conf::CONF_GLOBAL));

  // Ignore 'errstr_' values. librdkafka guards against "invalid" values. 'errstr_' is only warning
  // if improper key is provided, we ignore those as those don't influent the consumer.
  for (auto const &x : configs) { kafka_conf_->set(x.first, x.second, errstr_); }

  // Kafka 0.9 > requires at least a group.id in the configuration so lets
  // make sure that is present.
  conf_res_ = kafka_conf_->get("group.id", conf_val);
  if (conf_res_ == RdKafka::Conf::ConfResult::CONF_UNKNOWN) {
    // CUDF_FAIL("Kafka `group.id` was not supplied in its configuration and is
    // required for operation");
    // TODO: What are options here? I would like to not include CUDA RT just for
    // error handling logic alone.
  }

  consumer_ = std::unique_ptr<RdKafka::KafkaConsumer>(
    RdKafka::KafkaConsumer::create(kafka_conf_.get(), errstr_));
}

int64_t kafka_consumer::get_committed_offset(std::string topic, int partition)
{
  std::vector<RdKafka::TopicPartition *> toppar_list;

  // vector of always size 1. Required by underlying library
  toppar_list.push_back(RdKafka::TopicPartition::create(topic, partition));

  // Query Kafka to populate the TopicPartitions with the desired offsets
  err_ = consumer_->committed(toppar_list, default_timeout_);

  return toppar_list[0]->offset();
}

std::string kafka_consumer::consume_range(std::string topic,
                                          int partition,
                                          int64_t start_offset,
                                          int64_t end_offset,
                                          int batch_timeout,
                                          std::string delimiter)
{
  std::string str_buffer;
  int64_t messages_read = 0;
  int64_t batch_size    = end_offset - start_offset;
  int64_t end           = now() + batch_timeout;
  int remaining_timeout = batch_timeout;

  update_consumer_toppar_assignment(topic, partition, start_offset);

  while (messages_read < batch_size) {
    RdKafka::Message *msg = consumer_->consume(remaining_timeout);

    if (msg->err() == RdKafka::ErrorCode::ERR_NO_ERROR) {
      str_buffer.append(static_cast<char *>(msg->payload()));
      str_buffer.append(delimiter);
      messages_read++;
    }

    remaining_timeout = end - now();
    if (remaining_timeout < 0) { break; }

    delete msg;
  }

  return str_buffer;
}

std::map<std::string, int64_t> kafka_consumer::get_watermark_offset(std::string topic,
                                                                    int partition,
                                                                    int timeout,
                                                                    bool cached)
{
  int64_t low;
  int64_t high;
  std::map<std::string, int64_t> results;

  if (cached == true) {
    err_ = consumer_->get_watermark_offsets(topic, partition, &low, &high);
  } else {
    err_ = consumer_->query_watermark_offsets(topic, partition, &low, &high, timeout);
  }

  if (err_ != RdKafka::ErrorCode::ERR_NO_ERROR) {
    if (err_ == RdKafka::ErrorCode::ERR__PARTITION_EOF) {
      results.insert(std::pair<std::string, int64_t>("low", low));
      results.insert(std::pair<std::string, int64_t>("high", high));
    } else {
      throw std::runtime_error(std::string(err2str(err_).c_str()));
    }
  } else {
    results.insert(std::pair<std::string, int64_t>("low", low));
    results.insert(std::pair<std::string, int64_t>("high", high));
  }

  return results;
}

bool kafka_consumer::commit_offset(std::string topic, int partition, int64_t offset)
{
  std::vector<RdKafka::TopicPartition *> partitions_;
  RdKafka::TopicPartition *toppar = RdKafka::TopicPartition::create(topic, partition, offset);
  if (toppar != NULL) {
    toppar->set_offset(offset);
    partitions_.push_back(toppar);
    err_ = consumer_->commitSync(partitions_);
    return true;
  } else {
    return false;
  }
}

bool kafka_consumer::unsubscribe()
{
  err_ = consumer_.get()->unassign();
  if (err_ != RdKafka::ERR_NO_ERROR) {
    // TODO: CUDF_FAIL here or??
    printf(
      "Timeout occurred while unsubscribing from Kafka Consumer "
      "assignments.\n");
    return false;
  } else {
    return true;
  }
}

bool kafka_consumer::close(int timeout)
{
  err_ = consumer_.get()->close();

  if (err_ != RdKafka::ERR_NO_ERROR) {
    // TODO: CUDF_FAIL here or??
    printf("Timeout occurred while closing Kafka Consumer\n");
    return false;
  } else {
    return true;
  }

  delete consumer_.get();
  delete kafka_conf_.get();
}

}  // namespace kafka
}  // namespace external
}  // namespace io
}  // namespace cudf
