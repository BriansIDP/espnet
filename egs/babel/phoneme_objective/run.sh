#!/bin/bash

# Copyright 2018 Johns Hopkins University (Matthew Wiesner)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh
. ./cmd.sh
. ./conf/lang.conf

# general configuration
backend=pytorch
stage=0        # start from 0 if you need to start from data preparation
ngpu=0          # number of gpus ("0" uses cpu, otherwise use gpu)
seed=1
debugmode=1
dumpdir=dump   # directory to dump full features
N=0            # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0      # verbose option
resume=        # Resume the training from snapshot

# feature configuration
do_delta=false # true when using CNN

# network archtecture
# encoder related
etype=vggblstmp # encoder architecture type
elayers=4
eunits=320
eprojs=320
subsample=1_2_2_1_1 # skip every n frame from input to nth layers
# decoder related
dlayers=1
dunits=300

# attention related
atype=location
adim=320
awin=5
aheads=4
aconv_chans=10
aconv_filts=100

# hybrid CTC/attention
mtlalpha=0.33

# Phoneme Objective
phoneme_objective_weight=0.33
phoneme_objective_layer=""

# Language prediction
predict_lang=""
predict_lang_alpha= #If you want to specify a fixed learning rate scaling factor
predict_lang_alpha_scheduler=ganin # To use a scheduler from a publication.

# label smoothing
lsm_type=unigram
lsm_weight=0.05

# minibatch related
batchsize=25
maxlen_in=800  # if input length  > maxlen_in, batchsize is automatically reduced
maxlen_out=150 # if output length > maxlen_out, batchsize is automatically reduced

# optimization related
opt=adadelta
epochs=20

# rnnlm related
lm_weight=1.0
use_lm=false

# decoding parameter
beam_size=20
penalty=0.0
maxlenratio=0.0
minlenratio=0.0
ctc_weight=0.3
recog_model=acc.best # set a model to be used for decoding: 'acc.best' or 'loss.best'

# exp tag
tag="" # tag for managing experiments.

langs="101 102 103 104 105 106 202 203 204 205 206 207 301 302 303 304 305 306 401 402 403"
recog="107 201 404 307"
adapt_lang=""

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

# Train Directories
train_set=train
train_dev=dev

# LM Directories
lmexpdir=exp/train_rnnlm_2layer_bs2048
lm_train_set=data/local/train.txt
lm_valid_set=data/local/dev.txt

recog_set=""
for l in ${recog}; do
  recog_set="eval_${l} ${recog_set}"
done
recog_set=${recog_set%% }

adapt_sets=""
for l in ${recog}; do
  adapt_sets="train_${l} dev_${l} ${adapt_sets}"
done
adapt_sets=${adapt_sets%% }

if [ $stage -le 0 ]; then
  echo "stage 0: Setting up individual languages"
  ./local/setup_languages.sh --langs "${langs}" --recog "${recog}" --FLP false

  # Commented out and not upsampling because we're mostly using Babel data and this hurts
  # performance.
  #for x in ${train_set} ${train_dev} ${recog_set}; do
  #  sed -i.bak -e "s/$/ sox -R -t wav - -t wav - rate 16000 dither | /" data/${x}/wav.scp
  #done

  if [[ $phoneme_objective_weight > 0.0 ]]; then
    for x in ${train_set} ${train_dev} ${recog_set} ${adapt_sets}; do
      echo ${x}
      awk '(NR==FNR) {a[$1]=$0; next} ($1 in a){print $0}' data/${x}/text ${phoneme_ali} > data/${x}/text.phn
      # Remove stress symbols
      sed -i -r 's/_["%]//g' data/${x}/text.phn
      # Remove tonal markers
      sed -i -r 's/_T[A-Z]+//g' data/${x}/text.phn
      # Remove Lithuanian rising and falling tones
      sed -i -r 's/_[RF]//g' data/${x}/text.phn
      ./utils/filter_scp.pl data/${x}/text.phn data/${x}/text > data/${x}/text.tmp
      mv data/${x}/text.tmp data/${x}/text 
      ./utils/fix_data_dir.sh data/${x}
    done
  fi
  exit
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ $stage -le 1 ]; then
  echo "stage 1: Feature extraction"
  fbankdir=fbank
  mfccdir=mfcc
  # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
  for x in ${train_set} ${train_dev} ${recog_set} ${adapt_sets}; do
      steps/make_mfcc_pitch_online.sh --cmd "$train_cmd" --nj 20 --mfcc-config conf/mfcc_hires.conf data/${x} exp/make_mfcc_pitch/${x} ${mfccdir}
      ./utils/fix_data_dir.sh data/${x}

      utils/data/limit_feature_dim.sh 0:39 \
        data/${x} data/${x}_nopitch
      ./utils/fix_data_dir.sh data/${x}_nopitch

      steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 20 \
        data/${x}_nopitch extractor/ data/${x}_ivectors

  done

  # This is commented out because we're using iVectors instead:
  # compute global CMVN
  #compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark
  #./utils/fix_data_dir.sh data/${train_set} 

  exp_name=`basename $PWD`
  # dump features for training
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
  utils/create_split_dir.pl \
      /export/b{10,11,12,13}/${USER}/espnet-data/egs/babel/${exp_name}/dump/${train_set}/delta${do_delta}/storage \
      ${feat_tr_dir}/storage
  fi
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
  utils/create_split_dir.pl \
      /export/b{10,11,12,13}/${USER}/espnet-data/egs/babel/${exp_name}/dump/${train_dev}/delta${do_delta}/storage \
      ${feat_dt_dir}/storage
  fi
  dump.sh --ivectors data/${train_set}_ivectors/ivector_online.scp --cmd "$train_cmd" --nj 20 --do_delta $do_delta \
      data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
  dump.sh --ivectors data/${train_dev}_ivectors/ivector_online.scp --cmd "$train_cmd" --nj 10 --do_delta $do_delta \
      data/${train_dev}/feats.scp data/${train_dev}/cmvn.ark exp/dump_feats/dev ${feat_dt_dir}
  for rtask in ${recog_set} ${adapt_sets}; do
      feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
      dump.sh --ivectors data/${rtask}_ivectors/ivector_online.scp --cmd "$train_cmd" --nj 10 --do_delta $do_delta \
            data/${rtask}/feats.scp data/${rtask}/cmvn.ark exp/dump_feats/recog/${rtask} \
            ${feat_recog_dir}
  done
  exit
fi

dict=data/lang_1char/${train_set}_units.txt
nlsyms=data/lang_1char/non_lang_syms.txt

echo "dictionary: ${dict}"
if [ ${stage} -le 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/

    text_set=""
    for l in ${adapt_sets}; do
      text_set="data/${l}/text ${text_set}"
    done
    text_set=${text_set%% }
    echo ${text_set}
    # Make sure the adaptation / recog languages have their symbols included
    mkdir -p data/${train_set}_adapt
    cat data/${train_set}/text ${text_set} > data/${train_set}_adapt/text

    echo "make a non-linguistic symbol list"
    cut -f 2- data/${train_set}_adapt/text | tr " " "\n" | sort | uniq | grep "<" > ${nlsyms}
    cat ${nlsyms}

    echo "make a dictionary"
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    text2token.py -s 1 -n 1 -l ${nlsyms} data/${train_set}_adapt/text | cut -f 2- -d" " | tr " " "\n" \
    | sort | uniq | grep -v -e '^\s*$' | grep -v '<unk>' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    echo "make json files"
    data2json.sh --feat ${feat_tr_dir}/feats.scp --nlsyms ${nlsyms} \
         data/${train_set} ${dict} > ${feat_tr_dir}/data.json
    data2json.sh --feat ${feat_dt_dir}/feats.scp --nlsyms ${nlsyms} \
         data/${train_dev} ${dict} > ${feat_dt_dir}/data.json
    for rtask in ${recog_set} ${adapt_sets}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        data2json.sh --feat ${feat_recog_dir}/feats.scp \
            --nlsyms ${nlsyms} data/${rtask} ${dict} > ${feat_recog_dir}/data.json
    done

    # Phoneme Objective
    if [[ ${phoneme_objective_weight} > 0.0 ]]; then
        text_set=""
        for l in ${adapt_sets}; do
          text_set="data/${l}/text.phn ${text_set}"
        done
        text_set=${text_set%% }
        cat data/${train_set}/text.phn ${text_set} > data/${train_set}_adapt/text.phn
        echo ${text_set}
        echo "<unk> 1" > ${dict}.phn
        cut -d' ' -f2- data/${train_set}_adapt/text.phn | tr " " "\n" | sort -u |\
        grep -v '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}.phn

        mv ${feat_tr_dir}/data.json ${feat_tr_dir}/data.gph.json
        mv ${feat_dt_dir}/data.json ${feat_dt_dir}/data.gph.json
        for rtask in ${recog_set} ${adapt_sets}; do
            feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
            mv ${feat_recog_dir}/data.json ${feat_recog_dir}/data.gph.json
        done

        ./utils/filter_scp.pl data/${train_set}/text \
            data/${train_set}/text.phn > data/${train_set}/text.phn.filt
        mv data/${train_set}/text.phn.filt data/${train_set}/text.phn

        data2json.sh --feat ${feat_tr_dir}/feats.scp \
                     --nlsyms ${nlsyms} \
                     --phn-text data/${train_set}/text.phn \
                     data/${train_set} ${dict}.phn \
                     > ${feat_tr_dir}/data.phn.json

        combine_multimodal_json.py ${feat_tr_dir}/data.json \
                                   ${feat_tr_dir}/data.{phn,gph}.json

        ./utils/filter_scp.pl data/${train_dev}/text \
            data/${train_dev}/text.phn > data/${train_dev}/text.phn.filt
        mv data/${train_dev}/text.phn.filt data/${train_dev}/text.phn

        data2json.sh --feat ${feat_dt_dir}/feats.scp \
                     --nlsyms ${nlsyms} \
                     --phn-text data/${train_dev}/text.phn \
                     data/${train_dev} ${dict}.phn \
                     > ${feat_dt_dir}/data.phn.json

        combine_multimodal_json.py ${feat_dt_dir}/data.json \
                                   ${feat_dt_dir}/data.{phn,gph}.json

        for rtask in ${recog_set} ${adapt_sets}; do
            feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
            ./utils/filter_scp.pl data/${rtask}/text \
                data/${rtask}/text.phn > data/${rtask}/text.phn.filt
            mv data/${rtask}/text.phn.filt data/${rtask}/text.phn

            data2json.sh --feat ${feat_recog_dir}/feats.scp \
                         --nlsyms ${nlsyms} \
                         --phn-text data/${rtask}/text.phn \
                         data/${rtask} ${dict}.phn \
                         > ${feat_recog_dir}/data.phn.json

            combine_multimodal_json.py ${feat_recog_dir}/data.json \
                                       ${feat_recog_dir}/data.{phn,gph}.json
        done

    fi
    exit
fi

if $use_lm; then
  lm_train_set=data/local/train.txt
  lm_valid_set=data/local/dev.txt
 
  # Make train and valid
  text2token.py --nchar 1 \
                --space "<space>" \
                --non-lang-syms data/lang_1char/non_lang_syms.txt \
                <(cut -d' ' -f2- data/${train_set}/text | head -100) |\
                sed 's/^ //;s/$/ <eos>/' | paste -d' ' -s > ${lm_train_set} 

  text2token.py --nchar 1 \
                --space "<space>" \
                --non-lang-syms data/lang_1char/non_lang_syms.txt \
                <(cut -d' ' -f2- data/${train_dev}/text | head -100) |\
                sed 's/^ //;s/$/ <eos>/' | paste -d' ' -s > ${lm_valid_set} 

  if [ ${ngpu} -gt 1 ]; then
        echo "LM training does not support multi-gpu. signle gpu will be used."
  fi


  ${cuda_cmd} ${lmexpdir}/train.log \
          lm_train.py \
          --ngpu ${ngpu} \
          --backend ${backend} \
          --verbose 1 \
          --outdir ${lmexpdir} \
          --train-label ${lm_train_set} \
          --valid-label ${lm_valid_set} \
          --dict ${dict}
fi

if [ -z ${tag} ]; then
    expdir=exp/${train_set}_${backend}_${etype}_e${elayers}_subsample${subsample}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}_aconvc${aconv_chans}_aconvf${aconv_filts}_mtlalpha${mtlalpha}_phoneme-weight${phoneme_objective_weight}_${opt}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}
    if ${do_delta}; then
        expdir=${expdir}_delta
    fi
    if [ ${phoneme_objective_layer} ]; then
        expdir=${expdir}_phonemelayer${phoneme_objective_layer}
    fi
    if [[ ${predict_lang} = normal ]]; then
        expdir=${expdir}_predictlang-${predict_lang_alpha}${predict_lang_alpha_scheduler}
    fi
    if [[ ${predict_lang} = adv ]]; then
        expdir=${expdir}_predictlang-adv-${predict_lang_alpha}${predict_lang_alpha_scheduler}
    fi
else
    expdir=exp/${train_set}_${backend}_${tag}
fi
mkdir -p ${expdir}
cp ./run.sh ${expdir} # Copy this run script to the exp dir so we know exactly what was run
echo $@ > ${expdir}/runargs.txt # All the arguments that were supplied to the run script.

if [ ${stage} -le 3 ]; then
    echo "stage 3: Network Training"

    # If we're not adapting, then just train on the standard multilingual
    # training set, otherwise train on the adaptation lang and resume from a
    # multilingual model
    if [[ -z ${adapt_lang} ]]; then
        feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}
        feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}
    else
        feat_tr_dir=${dumpdir}/train_${adapt_lang}/delta${do_delta}
        feat_dt_dir=${dumpdir}/dev_${adapt_lang}/delta${do_delta}
        resume=exp/${expdir}/results/snapshot.ep.${epochs}
        expdir=${exp_dir}_adapt_${adapt_lang}
        mkdir -p ${expdir}
    fi

    train_cmd2="${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --verbose ${verbose} \
        --resume ${resume} \
        --seed ${seed} \
        --train-json ${feat_tr_dir}/data.json \
        --valid-json ${feat_dt_dir}/data.json \
        --etype ${etype} \
        --elayers ${elayers} \
        --eunits ${eunits} \
        --eprojs ${eprojs} \
        --subsample ${subsample} \
        --dlayers ${dlayers} \
        --dunits ${dunits} \
        --atype ${atype} \
        --adim ${adim} \
        --awin ${awin} \
        --aheads ${aheads} \
        --aconv-chans ${aconv_chans} \
        --aconv-filts ${aconv_filts} \
        --mtlalpha ${mtlalpha} \
        --lsm-type ${lsm_type} \
        --lsm-weight ${lsm_weight} \
        --batch-size ${batchsize} \
        --maxlen-in ${maxlen_in} \
        --maxlen-out ${maxlen_out} \
        --opt ${opt} \
        --epochs ${epochs} \
        --phoneme_objective_weight ${phoneme_objective_weight}"
    if [[ ${phoneme_objective_layer} ]]; then
        train_cmd2="${train_cmd2} --phoneme_objective_layer ${phoneme_objective_layer}"
    fi
    if [[ ! -z ${predict_lang} ]]; then
        train_cmd2="${train_cmd2} --predict_lang ${predict_lang}"
        if [[ ! -z ${predict_lang_alpha} ]]; then
            train_cmd2="${train_cmd2} --predict_lang_alpha ${predict_lang_alpha}"
        elif [[ ! -z ${predict_lang_alpha_scheduler} ]]; then
            train_cmd2="${train_cmd2} --predict_lang_alpha_scheduler \
                                    ${predict_lang_alpha_scheduler}"
        fi
    fi
    echo "train_cmd2: $train_cmd2"
    echo "expdir: $expdir"
    ${train_cmd2}
    exit
fi

if [ ${stage} -le 4 ]; then
    echo "stage 4: Decoding"
    nj=32

    extra_opts=""
    if $use_lm; then
      extra_opts="--rnnlm ${lmexpdir}/rnnlm.model.best --lm-weight ${lm_weight} ${extra_opts}"
    fi

    for rtask in ${recog_set}; do
    (
        decode_dir=decode_${rtask}_beam${beam_size}_e${recog_model}_p${penalty}_len${minlenratio}-${maxlenratio}
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

    # Since we currently don't have phoneme transcriptions for evaluation data, just use data.gph.json
    cp ${feat_recog_dir}/data.gph.json ${feat_recog_dir}/data.json
        # split data
        splitjson.py --parts ${nj} ${feat_recog_dir}/data.json 

        #### use CPU for decoding
        ngpu=0

        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --recog-json ${feat_recog_dir}/split${nj}utt/data.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/model.${recog_model}  \
            --model-conf ${expdir}/results/model.conf  \
            --beam-size ${beam_size} \
            --penalty ${penalty} \
            --ctc-weight ${ctc_weight} \
            --maxlenratio ${maxlenratio} \
            --minlenratio ${minlenratio} \
            ${extra_opts} &
        wait

        score_sclite.sh --wer true --nlsyms ${nlsyms} ${expdir}/${decode_dir} ${dict}

    ) &
    done
    wait
    echo "Finished"
fi

