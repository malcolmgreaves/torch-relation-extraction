--
-- User: pat
-- Date: 2/5/16
--

package.path = package.path .. ";src/?.lua;src/nn-modules/?.lua;src/eval/?.lua"
require 'SentenceClassifier'

local PoolClassifier, parent = torch.class('PoolClassifier', 'SentenceClassifier')


function PoolClassifier:__init(params)
    parent:__init(params)
    self.ep_pattern_map = {}
    self.pattern_tensor_map = {}
    self.ep_count = 0
end


--- process the candidate file and convert to torch ---
function PoolClassifier:process_file(vocab_map, dictionary)
    local line_num = 0
    local max_seq = 0
    local data = {}
    print('Processing data')
    for line in io.lines(self.params.candidates)
    do
        local enitity_pair, pattern, out_line, pattern_tensor, tac_tensor, seq_len = self:process_line(line, vocab_map, dictionary)
        if pattern_tensor:size(2) <= self.params.maxSeq then
            pattern_tensor = pattern_tensor:view(pattern_tensor:size(1), 1, pattern_tensor:size(2))
            -- pad all patterns up to consistent max seq length
            if pattern_tensor:size(3) < self.params.maxSeq then
                local pad_length = self.params.maxSeq - pattern_tensor:size(3)
                local pad_tensor = torch.Tensor(1, 1, pad_length):fill(self.params.padIdx)
                pattern_tensor = pattern_tensor:cat(pad_tensor)
            end
            if #self.kb_encoder:findModules('nn.EncoderPool') > 0 then tac_tensor = tac_tensor:view(tac_tensor:size(1), 1, tac_tensor:size(2)) end

            -- map each entity pair to a list of the pattern strings we saw it with
            if not self.ep_pattern_map[enitity_pair] then self.ep_count = self.ep_count+1; self.ep_pattern_map[enitity_pair] = {} end
            if not self.ep_pattern_map[enitity_pair][pattern] then self.ep_pattern_map[enitity_pair][pattern] = true end
            -- map each pattern string to its encoded vector
            if not self.pattern_tensor_map[pattern] then self.pattern_tensor_map[pattern] = pattern_tensor end

            max_seq = math.max(seq_len, max_seq)
            if not data[enitity_pair] then data[enitity_pair] = {out_line={}, tac_tensor={}} end
            local enitity_pair_data = data[enitity_pair]
            table.insert(enitity_pair_data.out_line, out_line)
            table.insert(enitity_pair_data.tac_tensor, tac_tensor)

            line_num = line_num + 1
            if line_num % 10000 == 0 then io.write('\rline : ' .. line_num); io.flush() end
        end
    end
    print ('\rProcessed ' .. line_num .. ' lines')
    return data, max_seq
end


--- score the data returned by process_file ---
function PoolClassifier:score_data(data, max_seq)
    print('Scoring data')
    -- open output file to write scored candidates file
    local out_file = io.open(self.params.outFile, "w")

    local ep_num = 0
    local out_file_scores = {}
    local max_score = -10000
    local min_score = 10000
    for ep, patterns in pairs(self.ep_pattern_map) do
        if ep_num % 10 == 0 then io.write('\rProcessing ep number ' .. ep_num .. ' of ' .. self.ep_count); io.flush() end
        local ep_data = data[ep]
        local ep_tensors_table = {}
        for pattern, _ in pairs(patterns) do table.insert(ep_tensors_table, self.pattern_tensor_map[pattern]) end

        -- join all the tac relation vectors we care about for this entity pair into a tensor
        local all_tac_relations_tensor = self.kb_encoder:forward(self:to_cuda(nn.JoinTable(1)(ep_data.tac_tensor))):clone()
        -- join all the patterns for this entity pair into a tensor
        local ep_tensor = nn.JoinTable(2)(ep_tensors_table)
        -- encode ep into a single vector
        local ep_encoded = self.text_encoder:forward(self:to_cuda(ep_tensor)):clone()
        if (ep_encoded:dim() < all_tac_relations_tensor:dim()) then ep_encoded = ep_encoded:view(ep_encoded:size(1), 1, ep_encoded:size(2)) end


        local out_lines = ep_data.out_line
        for i = 1, #out_lines do
            local x = {all_tac_relations_tensor:narrow(1,i,1), ep_encoded }
            local score = self.net:get(2):get(1)(x)[1]
            max_score = math.max(score, max_score)
            min_score = math.min(score, min_score)
            out_file_scores[out_lines[i]] = score
        end
        ep_num = ep_num + 1
    end
    for out_line, score in pairs(out_file_scores) do
        local normalized_score = (score - min_score) / (max_score - min_score)
        out_file:write(out_line .. normalized_score .. '\n')
    end

    out_file:close()
end
