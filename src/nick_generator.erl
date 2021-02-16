%%%-------------------------------------------------------------------
%%% File    : nick_generator.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Generate random nickname
%%% Created : 17 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2019   Redsolution OÜ
%%%
%%% This program is free software: you can redistribute it and/or
%%% modify it under the terms of the GNU Affero General Public License as
%%% published by the Free Software Foundation, either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(nick_generator).
-author('andrey.gagarin@redsolution.com').
%% API
-export([random_nick/3,get_avatar_file/1, init/1, handle_call/3, handle_cast/2]).
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1]).
-export([merge_avatar/3]).
%%-export([delete_previous_block/3]).
-behavior(gen_mod).
-behavior(gen_server).
-include("logger.hrl").
-include("xmpp.hrl").

%% records
-record(state, {host = <<"">> :: binary()}).


-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

-spec stop(binary()) -> ok.
stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

%%mod_options(_) ->
%%  [].

mod_opt_type(pre_generated_images) ->
  fun iolist_to_binary/1;
mod_opt_type(pre_generated_images_count) ->
  fun (I) when is_integer(I), I > 0 -> I end.

mod_options(_Host) ->
  [
    %% Required option
    pre_generated_images,
    pre_generated_images_count
  ].

depends(_, _) ->
  [{mod_groupchat_vcard, hard}].

init([Host, _Opts]) ->
  pre_generation(Host),
  {ok, #state{host = Host}}.

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast({update,Server,File}, State) ->
  ?INFO_MSG("Delete old file ~p and generate new",[File]),
  file:delete(File),
  generate_image(Server,1),
  {noreply, State}.

new_adjectives() ->
  [
    "Accepting",
    "Accomplished",
    "Aggravated",
    "Agreeable",
    "Alone",
    "Amazed",
    "Ambivalent",
    "Amused",
    "Angry",
    "Animated",
    "Annoyed",
    "Anxious",
    "Apathetic",
    "Appreciative",
    "Ashamed",
    "Attractive",
    "Awake",
    "Awestruck",
    "Awful",
    "Bashful",
    "Beautiful",
    "Bewildered",
    "Bitter",
    "Bittersweet",
    "Blah",
    "Blank",
    "Blissful",
    "Bold",
    "Bored",
    "Bouncy",
    "Brave",
    "Calm",
    "Candid",
    "Cautious",
    "Cheerful",
    "Chilly",
    "Chipper",
    "Clever",
    "Cold",
    "Comfortable",
    "Complacent",
    "Composed",
    "Confident",
    "Confused",
    "Content",
    "Contented",
    "Cool",
    "Cranky",
    "Crappy",
    "Crazy",
    "Crushed",
    "Curious",
    "Cynical",
    "Delightful",
    "Depressed",
    "Determined",
    "Devious",
    "Dirty",
    "Disappointed",
    "Discontent",
    "Disenchanted",
    "Disgruntled",
    "Disgusted",
    "Distressed",
    "Ditzy",
    "Dorky",
    "Drained",
    "Dreadful",
    "Drunk",
    "Earnest",
    "Easy",
    "Easygoing",
    "Ecstatic",
    "Elated",
    "Encouraging",
    "Energetic",
    "Enraged",
    "Enthralled",
    "Envious",
    "Evenhanded",
    "Evil",
    "Exanimate",
    "Excited",
    "Exhausted",
    "Festive",
    "Flirty",
    "Free",
    "Fresh",
    "Frustrated",
    "Full",
    "Geeky",
    "Gentle",
    "Giddy",
    "Giggly",
    "Glad",
    "Gloomy",
    "Glum",
    "Good",
    "Grateful",
    "Groggy",
    "Grouchy",
    "Grumpy",
    "Guilty",
    "Happy",
    "Heavy",
    "High",
    "Hopeful",
    "Horrified",
    "Hostile",
    "Hot",
    "Hungry",
    "Hurtful",
    "Hyper",
    "Impressed",
    "Indescribable",
    "Indifferent",
    "Infuriated",
    "Intelligent",
    "Irate",
    "Irritated",
    "Jealous",
    "Jolly",
    "Joyful",
    "Jubilant",
    "Kind",
    "Lazy",
    "Lethargic",
    "Listless",
    "Lonely",
    "Loved",
    "Loving",
    "Mad",
    "Melancholy",
    "Mellow",
    "Merry",
    "Mischievous",
    "Miserable",
    "Moody",
    "Morose",
    "Mysterious",
    "Nasty",
    "Naughty",
    "Nerdy",
    "Nervous",
    "Neutral",
    "Nonpartisan",
    "Numb",
    "Obnoxious",
    "Okay",
    "Open",
    "Oppressive",
    "Optimistic",
    "Overbearing",
    "Passive",
    "Peaceful",
    "Pessimistic",
    "Pleased",
    "Pragmatic",
    "Predatory",
    "Proud",
    "Quixotic",
    "Quizzical",
    "Recumbent",
    "Refreshed",
    "Rejected",
    "Rejuvenated",
    "Relaxed",
    "Relieved",
    "Religious",
    "Resentful",
    "Reserved",
    "Respectful",
    "Restless",
    "Rushed",
    "Sad",
    "Sadistic",
    "Sarcastic",
    "Sardonic",
    "Satisfied",
    "Secretive",
    "Secular",
    "Selfish",
    "Serene",
    "Shocked",
    "Shy",
    "Sick",
    "Silly",
    "Sleepy",
    "Smart",
    "Sour",
    "Stressed",
    "Strong",
    "Supportive",
    "Surprised",
    "Sweet",
    "Sympathetic",
    "Tearful",
    "Tense",
    "Terrible",
    "Thankful",
    "Tired",
    "Touched",
    "Tranquil",
    "Ugly",
    "Uncomfortable",
    "Upbeat",
    "Vivacious",
    "Warm",
    "Weak",
    "Weird",
    "Wonderful"
  ].

  adjectives() ->
[
"Adorable",
"Amazing",
"Brave",
"Calm",
"Careful",
"Classical",
"Clean",
"Confident",
"Delightful",
"Eager",
"Efficient",
"Electronic",
"Elegant",
"Famous",
"Fancy",
"Fresh",
"Futuristic",
"Gentle",
"Glamorous",
"Handsome",
"Happy",
"Helpful",
"Hungry",
"Impressive",
"Jolly",
"Kind",
"Lively",
"Logical",
"Magnificent",
"Nice",
"Ordinary",
"Perfect",
"Pleasant",
"Practical",
"Pragmatic",
"Proud",
"Rare",
"Reasonable",
"Rich",
"Silly",
"Snowy",
"Sparkling",
"Sunny",
"Suspicious",
"Technical",
"Thankful",
"Unusual",
"Valuable",
"Wicked",
"Witty",
"Wonderful",
"Zealous"].

animals()->
  ["Abyssinian",
    "Affenpinscher",
    "African Bush Elephant",
    "African Civet",
    "African Clawed Frog",
    "African Forest Elephant",
    "African Palm Civet",
    "African Penguin",
    "African Tree Toad",
    "African Wild Dog",
    "Albatross",
    "Aldabra Giant Tortoise",
    "Alligator",
    "Angelfish",
    "Ant",
    "Anteater",
    "Antelope",
    "Arctic Fox",
    "Arctic Hare",
    "Arctic Wolf",
    "Armadillo",
    "Asian Elephant",
    "Asian Palm Civet",
    "Australian Mist",
    "Avocet",
    "Axolotl",
    "Aye Aye",
    "Baboon",
    "Bactrian Camel",
    "Badger",
    "Balinese",
    "Banded Palm Civet",
    "Bandicoot",
    "Barn Owl",
    "Barnacle",
    "Barracuda",
    "Basking Shark",
    "Bat",
    "Bear",
    "Beaver",
    "Bengal Tiger",
    "Bird",
    "Bison",
    "Black Bear",
    "Black Rhinoceros",
    "Bobcat",
    "Bornean Orang-utan",
    "Borneo Elephant",
    "Bottle Nosed Dolphin",
    "Brown Bear",
    "Budgerigar",
    "Buffalo",
    "Bumble Bee",
    "Burrowing Frog",
    "Butterfly",
    "Camel",
    "Capybara",
    "Caracal",
    "Cassowary",
    "Caterpillar",
    "Centipede",
    "Chameleon",
    "Cheetah",
    "Chinchilla",
    "Chinook",
    "Chinstrap Penguin",
    "Chipmunk",
    "Cichlid",
    "Clouded Leopard",
    "Coati",
    "Collared Peccary",
    "Common Buzzard",
    "Common Frog",
    "Coral",
    "Cougar",
    "Cow",
    "Coyote",
    "Crane",
    "Crested Penguin",
    "Crocodile",
    "Cross River Gorilla",
    "Curly Coated Retriever",
    "Cuttlefish",
    "Dachshund",
    "Dalmatian",
    "Deer",
    "Dolphin",
    "Dormouse",
    "Dragon",
    "Dragonfly",
    "Duck",
    "Dusky Dolphin",
    "Dwarf Fortress",
    "Eagle",
    "Earwig",
    "Echidna",
    "Egyptian Mau",
    "Electric Eel",
    "Elephant",
    "Elephant Seal",
    "Emperor Penguin",
    "Emperor Tamarin",
    "Emu",
    "Falcon",
    "Fennec Fox",
    "Flamingo",
    "Flying Squirrel",
    "Fox",
    "Frigatebird",
    "Frog",
    "Fur Seal",
    "Galapagos Penguin",
    "Galapagos Tortoise",
    "Geoffroys Tamarin",
    "Gerbil",
    "German Pinscher",
    "Giant Clam",
    "Gibbon",
    "Giraffe",
    "Goat",
    "Golden Lion Tamarin",
    "Goose",
    "Gopher",
    "Grasshopper",
    "Grey Reef Shark",
    "Grey Seal",
    "Grizzly Bear",
    "Guinea Fowl",
    "Guinea Pig",
    "Guppy",
    "Hammerhead Shark",
    "Hamster",
    "Hare",
    "Harrier",
    "Havanese",
    "Hedgehog",
    "Heron",
    "Howler Monkey",
    "Humboldt Penguin",
    "Hummingbird",
    "Humpback Whale",
    "Hyena",
    "Iguana",
    "Impala",
    "Jackal",
    "Jaguar",
    "Kakapo",
    "Kangaroo",
    "King Penguin",
    "Kingfisher",
    "Kiwi",
    "Koala",
    "Komodo Dragon",
    "Kudu",
    "Lemming",
    "Leopard",
    "Liger",
    "Lion",
    "Lionfish",
    "Little Penguin",
    "Lizard",
    "Lynx",
    "Macaroni Penguin",
    "Macaw",
    "Magellanic Penguin",
    "Magpie",
    "Malayan Civet",
    "Malayan Tiger",
    "Maltese",
    "Mandrill",
    "Manta Ray",
    "Markhor",
    "Masked Palm Civet",
    "Mastiff",
    "Mayfly",
    "Meerkat",
    "Millipede",
    "Monitor Lizard",
    "Monte Iberia Eleuth",
    "Moorhen",
    "Moose",
    "Moray Eel",
    "Moth",
    "Mountain Lion",
    "Mouse",
    "Newt",
    "Nightingale",
    "Ocelot",
    "Octopus",
    "Okapi",
    "Opossum",
    "Ostrich",
    "Otter",
    "Oyster",
    "Pademelon",
    "Panther",
    "Parrot",
    "Pekingese",
    "Pelican",
    "Penguin",
    "Pheasant",
    "Pied Tamarin",
    "Piranha",
    "Platypus",
    "Pointer",
    "Polar Bear",
    "Pond Skater",
    "Poodle",
    "Porcupine",
    "Possum",
    "Prawn",
    "Puffer Fish",
    "Puffin",
    "Pug",
    "Puma",
    "Purple Emperor",
    "Quail",
    "Quetzal",
    "Quokka",
    "Quoll",
    "Rabbit",
    "Radiated Tortoise",
    "Red Panda",
    "Red Wolf",
    "Red-handed Tamarin",
    "Reindeer",
    "Rhinoceros",
    "River Dolphin",
    "River Turtle",
    "Rock Hyrax",
    "Rockhopper Penguin",
    "Roseate Spoonbill",
    "Royal Penguin",
    "Sabre-Toothed Tiger",
    "Saint Bernard",
    "Salamander",
    "Sand Lizard",
    "Saola",
    "Sea Dragon",
    "Sea Otter",
    "Sea Slug",
    "Sea Squirt",
    "Sea Turtle",
    "Seahorse",
    "Seal",
    "Serval",
    "Sheep",
    "Shrimp",
    "Siberian Tiger",
    "Silver Dollar",
    "Sloth",
    "Slow Worm",
    "Snapping Turtle",
    "Snowshoe",
    "Snowy Owl",
    "Sparrow",
    "Spectacled Bear",
    "Sponge",
    "Squid",
    "Squirrel",
    "Stellers Sea Cow",
    "Stick Insect",
    "Stoat",
    "Striped Rocket Frog",
    "Sun Bear",
    "Swan",
    "Tapir",
    "Tarsier",
    "Tasmanian Devil",
    "Tawny Owl",
    "Tetra",
    "Thorny Devil",
    "Tibetan Mastiff",
    "Tiffany",
    "Tiger",
    "Tiger Salamander",
    "Tortoise",
    "Toucan",
    "Tropicbird",
    "Tuatara",
    "Uakari",
    "Uguisu",
    "Umbrellabird",
    "Vampire Bat",
    "Vulture",
    "Wallaby",
    "Walrus",
    "Warthog",
    "Water Buffalo",
    "Water Dragon",
    "Rhinoceros",
    "White Tiger",
    "Wildebeest",
    "Wolf",
    "Woodlouse",
    "Woodpecker",
    "Wrasse",
    "X-Ray Tetra",
    "Yak",
    "Yellow-Eyed Penguin",
    "Yorkshire Terrier",
    "Zebra",
    "Zebu",
    "Zonkey",
    "Zorse"].

random_nick(Server, User, Chat) ->
  Nick = mod_groupchat_users:get_nick_in_chat(Server,User,Chat),
  NickLength = string:length(Nick),
  case NickLength of
    0 ->
      NewNick = generate_nick_and_avatar(Server, User, Chat),
      check_unique_and_update(Server,User,Chat,NewNick);
    _ ->
      Nick
  end.

check_unique_and_update(Server, User, Chat, Nick) ->
  case mod_groupchat_users:is_duplicated_nick(Server,Chat,Nick,User) of
    false ->
      Nick;
    _ ->
      Adjectives = new_adjectives(),
      LengthAdjectives = length(Adjectives),
      RandomAdjectivePosition = rand:uniform(LengthAdjectives),
      RandomAdjective = list_to_binary(lists:nth(RandomAdjectivePosition,Adjectives)),
      UpdatedNick = <<RandomAdjective/binary," ", Nick/binary>>,
      UpdatedNick
  end.

random_avatar(Server, User, Chat, AvatarUrl, File) ->
  {AvatarID, Type, AvatarSize} = get_image_info(File),
  AvatarType = <<"image/",Type/binary>>,
  Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
  Name = <<AvatarID/binary, ".", Type/binary>>,
  FileName = <<Path/binary, "/" , Name/binary>>,
  file:write_file(binary_to_list(FileName), File),
  mod_groupchat_vcard:update_avatar(Server, User, Chat, AvatarID, AvatarType, AvatarSize, AvatarUrl).

get_image_info(File) ->
  Hash = mod_groupchat_vcard:get_hash(File),
  Type = atom_to_binary(eimp:get_type(File), latin1),
  Size = byte_size(File),
  {Hash,Type,Size}.


old_random_nick() ->
  Animals = animals(),
  Adjectives = adjectives(),
  LengthAnimals = length(Animals),
  LengthAdjectives = length(Adjectives),
  RandomAnimalPosition = rand:uniform(LengthAnimals),
  RandomAdjectivePosition = rand:uniform(LengthAdjectives),
  RandomAnimal = list_to_binary(lists:nth(RandomAnimalPosition,Animals)),
  RandomAdjective = list_to_binary(lists:nth(RandomAdjectivePosition,Adjectives)),
  RandomNum = integer_to_binary(rand:uniform(99)),
  Nick = <<RandomAdjective/binary," ",RandomAnimal/binary," ",
    RandomNum/binary>>,
  Nick.

generate_nick_and_avatar(Server, User, Chat) ->
  case get_avatar_file(Server) of
    {ok,FileName,Bin} ->
      Url = mod_groupchat_vcard:get_url(Server),
      AvatarUrl = <<Url/binary, "/", FileName/binary>>,
      random_avatar(Server, User, Chat, AvatarUrl, Bin),
      hd(binary:split(FileName,<<".">>));
    _ ->
      old_random_nick()
  end.

get_avatar_file(Server) ->
  PreImages = gen_mod:get_module_opt(Server,?MODULE,pre_generated_images),
  case file:list_dir(PreImages) of
    {ok,[]} ->
      generate_files(Server,[]),
      error;
    {ok,Files} ->
      FilesLength = length(Files),
      RandomPicturePosition =  rand:uniform(FilesLength),
      FileName= list_to_binary(lists:nth(RandomPicturePosition,Files)),
      FullPath = <<PreImages/binary, "/">>,
      File = <<FullPath/binary, FileName/binary>>,
      case file:read_file(File) of
        {ok,Bin} ->
          Proc = gen_mod:get_module_proc(Server, ?MODULE),
          gen_server:cast(Proc, {update,Server,File}),
          {ok,FileName,Bin};
        _ ->
          error
      end;
    _ ->
      error
  end.

pre_generation(Host) ->
  ImagePath = gen_mod:get_module_opt(Host,?MODULE,pre_generated_images),
  case file:list_dir(ImagePath) of
    {ok,Files} ->
      generate_files(Host,Files);
    {error,_Err} ->
      case file:make_dir(ImagePath) of
        ok ->
          case file:list_dir(ImagePath) of
            {ok,Files} ->
              generate_files(Host,Files);
            _ ->
              ?ERROR_MSG("Internal error in nick_generator",[])
          end;
        _ ->
          ?ERROR_MSG("Internal error in nick_generator",[])
      end
  end.

generate_files(Host,Files) ->
  ImagesCount = gen_mod:get_module_opt(Host,?MODULE,pre_generated_images_count),
  CurrentAmount = length(Files),
  NeedToGenerate = ImagesCount - CurrentAmount,
  generate_image(Host,NeedToGenerate).


generate_image(_Host,0) ->
  ok;
generate_image(Host,Count) when Count > 0 ->
  generate_image(Host),
  generate_image(Host, Count - 1);
generate_image(_Host,_Count) ->
  ok.

generate_image(Host) ->
  Path = filename:absname(gen_mod:get_module_opt(Host,?MODULE,pre_generated_images)),
  CMD = binary_to_list(<<"python3 generateavatar.py ", Path/binary>>),
  Result = list_to_binary(os:cmd(CMD)),
  FileName = re:replace(Result, "(^\\s+)|(\\s+$)", "", [global,{return,binary}]),
  File = filename:join(Path,FileName),
  case file:read_file(File) of
    {ok,_F} ->
      ok;
    _ ->
      ?ERROR_MSG("Problem to generate image",[])
  end.


%% Merge avatars

merge_avatar(Avatar1, Avatar2, FullPath) ->
  CMD = binary_to_list(<<"python3 mergeavatars.py ", "'", Avatar1/binary, "' '", Avatar2/binary, "' ", "'",FullPath/binary,"'">>),
  string:chomp(list_to_binary(os:cmd(CMD))).