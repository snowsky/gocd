##########################################################################
# Copyright 2015 ThoughtWorks, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################

module ApiV1
  module Admin
    class PipelinesController < ApiV1::BaseController
      before_action :check_admin_user_and_401
      before_action :load_pipeline, only: [:show]
      before_action :check_if_pipeline_by_same_name_already_exists, :check_group_not_blank, only: [:create]
      before_action :check_for_stale_request, :check_for_attempted_pipeline_rename, only: [:update]

      def show
        json = ApiV1::Config::PipelineConfigRepresenter.new(@pipeline_config).to_hash(url_builder: self)
        if stale?(etag: get_etag_for_pipeline(@pipeline_config.name.to_s, json))
          render DEFAULT_FORMAT => json
        end
      end

      def create
        result = HttpLocalizedOperationResult.new
        get_pipeline_from_request
        pipeline_config_service.createPipelineConfig(current_user, @pipeline_config_from_request, result, params[:group])
        handle_config_save_or_update_result(result, @pipeline_config_from_request.name.to_s)
        if result.isSuccessful
          pipeline_pause_service.pause(@pipeline_config_from_request.name.to_s, "Under construction", current_user)
        end
      end

      def update
        result = HttpLocalizedOperationResult.new
        get_pipeline_from_request
        pipeline_config_service.updatePipelineConfig(current_user, @pipeline_config_from_request, result)
        handle_config_save_or_update_result(result)
      end

      private

      def get_pipeline_from_request
        @pipeline_config_from_request ||= PipelineConfig.new.tap do |config|
          ApiV1::Config::PipelineConfigRepresenter.new(config).from_hash(params[:pipeline], {go_config: go_config_service.getCurrentConfig()})
        end
      end

      def handle_config_save_or_update_result(result, pipeline_name = params[:name])
        if result.isSuccessful
          load_pipeline(pipeline_name)
          json = ApiV1::Config::PipelineConfigRepresenter.new(@pipeline_config).to_hash(url_builder: self)
          response.etag = [get_etag_for_pipeline(@pipeline_config.name.to_s, json)]
          render DEFAULT_FORMAT => json
        else
          json = ApiV1::Config::PipelineConfigRepresenter.new(@pipeline_config_from_request).to_hash(url_builder: self)
          render_http_operation_result(result, {data: json})
        end
      end


      def check_for_attempted_pipeline_rename
        unless CaseInsensitiveString.new(params[:pipeline][:name]) == CaseInsensitiveString.new(params[:name])
          result = HttpLocalizedOperationResult.new
          result.notAcceptable(LocalizedMessage::string("PIPELINE_RENAMING_NOT_ALLOWED"))
          render_http_operation_result(result)
        end
      end

      def check_for_stale_request
        if (request.env["HTTP_IF_MATCH"] != "\"#{Digest::MD5.hexdigest(get_etag_for_pipeline_from_cache(params[:name]))}\"")
          result = HttpLocalizedOperationResult.new
          result.stale(LocalizedMessage::string("STALE_PIPELINE_CONFIG", params[:name]))
          render_http_operation_result(result)
        end
      end

      def load_pipeline(pipeline_name = params[:name])
        @pipeline_config = pipeline_config_service.getPipelineConfig(pipeline_name)
        raise RecordNotFound if @pipeline_config.nil?
      end

      def get_etag_for_pipeline(pipeline_name, json)
        cache_key = pipeline_name.downcase
        etag      = go_cache.get("GO_PIPELINE_CONFIGS_ETAGS_CACHE", cache_key)

        unless etag
          etag = Digest::MD5.hexdigest(JSON.generate(json))
          go_cache.put("GO_PIPELINE_CONFIGS_ETAGS_CACHE", cache_key, etag)
        end
        etag
      end

      def get_etag_for_pipeline_from_cache(pipeline_name)
        cache_key = pipeline_name.downcase
        etag      = go_cache.get("GO_PIPELINE_CONFIGS_ETAGS_CACHE", cache_key)

        unless (etag)
          load_pipeline
          json = ApiV1::Config::PipelineConfigRepresenter.new(@pipeline_config).to_hash(url_builder: self)
          etag = get_etag_for_pipeline(pipeline_name, json)
        end
        etag
      end

      def check_if_pipeline_by_same_name_already_exists
        if (!pipeline_config_service.getPipelineConfig(params[:name]).nil?)
          result = HttpLocalizedOperationResult.new
          result.unprocessableEntity(LocalizedMessage::string("CANNOT_CREATE_PIPELINE_ALREADY_EXISTS", params[:name]))
          render_http_operation_result(result)
        end
      end

      def check_group_not_blank
        if (params[:group].blank?)
          result = HttpLocalizedOperationResult.new
          result.unprocessableEntity(LocalizedMessage::string("PIPELINE_GROUP_MANDATORY_FOR_PIPELINE_CREATE"))
          render_http_operation_result(result)
        end
      end
    end
  end
end
