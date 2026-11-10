import 'package:mnn_local_llm/mnn_local_llm.dart';

const String systemPrompt =
    '你是 MNN-Pocket，一个完全运行在手机本地的 AI 助手。回答简洁、准确，优先使用用户的语言。';

const String _modelBase =
    'https://modelscope.cn/models/MNN/MNN-Pocket-0.3B-MNN/resolve/master';

/// MNN-Pocket-0.3B, INT4 W4A16, MNN runtime on CPU.
const MnnModel pocketModel = MnnModel(
  id: 'mnn-pocket-0.3b',
  name: 'MNN-Pocket 0.3B',
  dirName: 'MNN-Pocket-0.3B-MNN',
  files: [
    MnnModelFile(name: 'config.json', url: '$_modelBase/config.json', bytes: 502),
    MnnModelFile(name: 'llm.mnn', url: '$_modelBase/llm.mnn', bytes: 953112),
    MnnModelFile(
      name: 'llm.mnn.weight',
      url: '$_modelBase/llm.mnn.weight',
      bytes: 171481330,
    ),
    MnnModelFile(
      name: 'llm_config.json',
      url: '$_modelBase/llm_config.json',
      bytes: 3237,
    ),
    MnnModelFile(
      name: 'tokenizer.mtok',
      url: '$_modelBase/tokenizer.mtok',
      bytes: 1710861,
    ),
  ],
  minRamGB: 1,
  context: 2048,
  chatTemplate: MnnChatTemplate(
    system: '<|im_start|>system\n{text}<|im_end|>\n',
    user: '<|im_start|>user\n{text}<|im_end|>\n',
    assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
    systemDefault: systemPrompt,
  ),
);

const MnnGenerationSettings defaultSettings = MnnGenerationSettings();
